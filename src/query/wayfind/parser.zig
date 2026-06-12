//! Wayfind textual parser: one pipeline string → one validated `ir.Plan`.
//!
//! The textual form is a thin front-end over the IR — every textual step
//! maps to one IR step (set ops map to two: push param + stack op), with
//! no rewriting and no planning. Parsed plans pass `ir.validate` before
//! being returned, so a successful parse is executable by construction.
//!
//! Grammar (whitespace insignificant, `#` starts a line comment):
//!
//!   query    = source , { "|" , step } , "|" , terminal ;
//!   source   = "from" , ( param | "node:" nat | "*" ) ;
//!   step     = expand | setop | filter ;
//!   expand   = dir , [ "(" rel ")" ] , [ range ] ;
//!   dir      = "out" | "in" | "both" ;
//!   range    = "{" nat ".." ( nat | "*" ) "}" | "*" ;     (default {1..1})
//!   setop    = ( "&" | "+" | "-" ) , param ;
//!   filter   = "degree" , "(" dir ")" , cmp , nat ;
//!   cmp      = "<" | "<=" | "==" | ">=" | ">" ;
//!   terminal = "ids" | "count" | "exists" | "edges" | "csr" ;
//!   param    = "$" , ident ;
//!   rel      = ident | nat ;
//!
//! Relation identifiers resolve through the caller-provided bindings;
//! numeric relations are accepted directly. Parameters are assigned dense
//! slots in order of first appearance; a repeated `$name` reuses its slot.

const std = @import("std");
const ir = @import("ir.zig");

/// Caller-provided name → relation mapping for textual relation idents.
pub const RelationBinding = struct {
    name: []const u8,
    value: u16,
};

pub const ParseError = ir.PlanError || std.mem.Allocator.Error || error{
    /// A token that no rule accepts at this position.
    UnexpectedToken,
    /// The query ended before the grammar was satisfied.
    UnexpectedEnd,
    /// A relation identifier with no binding.
    UnknownRelation,
    /// A numeric literal out of range for its field (u16 rel/hops, u32 node).
    NumberOverflow,
    /// 0xFFFF is the ANY sentinel, not a valid explicit relation.
    ReservedRelation,
};

/// A parsed query: the plan plus the parameter name table (dense slots, in
/// order of first appearance). Owns its memory; the source string may be
/// freed after `parse` returns.
pub const Parsed = struct {
    steps: []ir.Step,
    param_names: [][]const u8,

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        for (self.param_names) |name| allocator.free(name);
        allocator.free(self.param_names);
        allocator.free(self.steps);
        self.* = undefined;
    }

    pub fn plan(self: *const Parsed) ir.Plan {
        return .{ .steps = self.steps, .param_count = @intCast(self.param_names.len) };
    }

    /// Slot of a named parameter, for building `exec.Params.sets`.
    pub fn paramSlot(self: *const Parsed, name: []const u8) ?u16 {
        for (self.param_names, 0..) |param_name, slot| {
            if (std.mem.eql(u8, param_name, name)) return @intCast(slot);
        }
        return null;
    }
};

pub fn parse(
    allocator: std.mem.Allocator,
    source: []const u8,
    relations: []const RelationBinding,
) ParseError!Parsed {
    var parser = Parser{
        .allocator = allocator,
        .tokenizer = .{ .source = source },
        .relations = relations,
    };
    defer parser.deinitWorking();
    errdefer parser.deinitOutput();

    try parser.parseQuery();

    const steps = try parser.steps.toOwnedSlice(allocator);
    errdefer allocator.free(steps);
    const param_names = try parser.param_names.toOwnedSlice(allocator);
    errdefer {
        for (param_names) |name| allocator.free(name);
        allocator.free(param_names);
    }

    const parsed = Parsed{ .steps = steps, .param_names = param_names };
    try ir.validate(parsed.plan());
    return parsed;
}

// ── Tokenizer ────────────────────────────────────────────────────────────

const Token = union(enum) {
    pipe,
    amp,
    plus,
    minus,
    dollar,
    lparen,
    rparen,
    lbrace,
    rbrace,
    star,
    dot_dot,
    colon,
    lt,
    le,
    eq_eq,
    ge,
    gt,
    ident: []const u8,
    nat: u64,
    end,
};

const Tokenizer = struct {
    source: []const u8,
    pos: usize = 0,

    fn next(self: *Tokenizer) ParseError!Token {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            switch (c) {
                ' ', '\t', '\r', '\n' => self.pos += 1,
                '#' => while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.pos += 1;
                },
                else => break,
            }
        }
        if (self.pos >= self.source.len) return .end;

        const c = self.source[self.pos];
        self.pos += 1;
        switch (c) {
            '|' => return .pipe,
            '&' => return .amp,
            '+' => return .plus,
            '-' => return .minus,
            '$' => return .dollar,
            '(' => return .lparen,
            ')' => return .rparen,
            '{' => return .lbrace,
            '}' => return .rbrace,
            '*' => return .star,
            ':' => return .colon,
            '.' => {
                if (self.pos < self.source.len and self.source[self.pos] == '.') {
                    self.pos += 1;
                    return .dot_dot;
                }
                return error.UnexpectedToken;
            },
            '<' => {
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    return .le;
                }
                return .lt;
            },
            '>' => {
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    return .ge;
                }
                return .gt;
            },
            '=' => {
                if (self.pos < self.source.len and self.source[self.pos] == '=') {
                    self.pos += 1;
                    return .eq_eq;
                }
                return error.UnexpectedToken;
            },
            '0'...'9' => {
                var value: u64 = c - '0';
                while (self.pos < self.source.len) {
                    const digit = self.source[self.pos];
                    if (digit < '0' or digit > '9') break;
                    value = std.math.mul(u64, value, 10) catch return error.NumberOverflow;
                    value = std.math.add(u64, value, digit - '0') catch return error.NumberOverflow;
                    self.pos += 1;
                }
                return .{ .nat = value };
            },
            'A'...'Z', 'a'...'z', '_' => {
                const start = self.pos - 1;
                while (self.pos < self.source.len) {
                    const ident_char = self.source[self.pos];
                    const is_ident = (ident_char >= 'A' and ident_char <= 'Z') or
                        (ident_char >= 'a' and ident_char <= 'z') or
                        (ident_char >= '0' and ident_char <= '9') or ident_char == '_';
                    if (!is_ident) break;
                    self.pos += 1;
                }
                return .{ .ident = self.source[start..self.pos] };
            },
            else => return error.UnexpectedToken,
        }
    }
};

// ── Parser ───────────────────────────────────────────────────────────────

const Parser = struct {
    allocator: std.mem.Allocator,
    tokenizer: Tokenizer,
    relations: []const RelationBinding,
    steps: std.ArrayList(ir.Step) = .empty,
    param_names: std.ArrayList([]const u8) = .empty,
    peeked: ?Token = null,

    fn deinitWorking(self: *Parser) void {
        self.steps.deinit(self.allocator);
        self.param_names.deinit(self.allocator);
    }

    fn deinitOutput(self: *Parser) void {
        for (self.param_names.items) |name| self.allocator.free(name);
    }

    fn nextToken(self: *Parser) ParseError!Token {
        if (self.peeked) |token| {
            self.peeked = null;
            return token;
        }
        return self.tokenizer.next();
    }

    fn peekToken(self: *Parser) ParseError!Token {
        if (self.peeked == null) self.peeked = try self.tokenizer.next();
        return self.peeked.?;
    }

    fn expectIdent(self: *Parser, keyword: []const u8) ParseError!void {
        const token = try self.nextToken();
        if (token == .end) return error.UnexpectedEnd;
        if (token != .ident or !std.mem.eql(u8, token.ident, keyword)) return error.UnexpectedToken;
    }

    fn expect(self: *Parser, comptime tag: std.meta.Tag(Token)) ParseError!void {
        const token = try self.nextToken();
        if (token == .end and tag != .end) return error.UnexpectedEnd;
        if (token != tag) return error.UnexpectedToken;
    }

    fn natAs(self: *Parser, comptime T: type) ParseError!T {
        const token = try self.nextToken();
        if (token == .end) return error.UnexpectedEnd;
        if (token != .nat) return error.UnexpectedToken;
        return std.math.cast(T, token.nat) orelse error.NumberOverflow;
    }

    fn append(self: *Parser, step: ir.Step) ParseError!void {
        try self.steps.append(self.allocator, step);
    }

    /// Dense slot for a parameter name; first appearance allocates.
    fn paramSlot(self: *Parser, name: []const u8) ParseError!u16 {
        for (self.param_names.items, 0..) |existing, slot| {
            if (std.mem.eql(u8, existing, name)) return @intCast(slot);
        }
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.param_names.append(self.allocator, owned);
        return @intCast(self.param_names.items.len - 1);
    }

    fn parseParamSlot(self: *Parser) ParseError!u16 {
        try self.expect(.dollar);
        const token = try self.nextToken();
        if (token != .ident) return error.UnexpectedToken;
        return self.paramSlot(token.ident);
    }

    fn parseQuery(self: *Parser) ParseError!void {
        try self.expectIdent("from");
        try self.parseSource();
        while (true) {
            switch (try self.nextToken()) {
                .pipe => if (try self.parseStepOrTerminal()) return,
                .end => return error.MissingTerminal,
                else => return error.UnexpectedToken,
            }
        }
    }

    fn parseSource(self: *Parser) ParseError!void {
        switch (try self.peekToken()) {
            .dollar => try self.append(.{ .op = .seed_param, .param = try self.parseParamSlot() }),
            .star => {
                _ = try self.nextToken();
                try self.append(.{ .op = .all_nodes });
            },
            .ident => |keyword| {
                if (!std.mem.eql(u8, keyword, "node")) return error.UnexpectedToken;
                _ = try self.nextToken();
                try self.expect(.colon);
                try self.append(.{ .op = .seed_node, .arg = try self.natAs(u32) });
            },
            .end => return error.UnexpectedEnd,
            else => return error.UnexpectedToken,
        }
    }

    /// Parses one pipeline segment. Returns true when it was the terminal
    /// (which also consumes the end of input).
    fn parseStepOrTerminal(self: *Parser) ParseError!bool {
        const token = try self.nextToken();
        switch (token) {
            .amp => try self.parseSetOp(.set_intersect),
            .plus => try self.parseSetOp(.set_union),
            .minus => try self.parseSetOp(.set_minus),
            .ident => |keyword| {
                if (directionByName(keyword)) |dir| {
                    try self.parseExpand(dir);
                } else if (std.mem.eql(u8, keyword, "degree")) {
                    try self.parseDegreeFilter();
                } else if (terminalByName(keyword)) |op| {
                    try self.append(.{ .op = op });
                    if (try self.nextToken() != .end) return error.UnexpectedToken;
                    return true;
                } else {
                    return error.UnexpectedToken;
                }
            },
            .end => return error.UnexpectedEnd,
            else => return error.UnexpectedToken,
        }
        return false;
    }

    fn parseSetOp(self: *Parser, op: ir.Op) ParseError!void {
        const slot = try self.parseParamSlot();
        try self.append(.{ .op = .seed_param, .param = slot });
        try self.append(.{ .op = op });
    }

    fn parseExpand(self: *Parser, dir: ir.Direction) ParseError!void {
        var rel: u16 = ir.ANY_RELATION;
        if (try self.peekToken() == .lparen) {
            _ = try self.nextToken();
            rel = try self.parseRelation();
            try self.expect(.rparen);
        }

        var hops: ir.Hops = .{ .min = 1, .max = 1 };
        switch (try self.peekToken()) {
            .star => {
                _ = try self.nextToken();
                hops = .{ .min = 1, .max = ir.UNBOUNDED };
            },
            .lbrace => {
                _ = try self.nextToken();
                hops.min = try self.natAs(u16);
                try self.expect(.dot_dot);
                switch (try self.nextToken()) {
                    .nat => |value| hops.max = std.math.cast(u16, value) orelse return error.NumberOverflow,
                    .star => hops.max = ir.UNBOUNDED,
                    else => return error.UnexpectedToken,
                }
                try self.expect(.rbrace);
            },
            else => {},
        }
        try self.append(.{ .op = .expand, .dir = dir, .rel = rel, .hops = hops });
    }

    fn parseRelation(self: *Parser) ParseError!u16 {
        switch (try self.nextToken()) {
            .nat => |value| {
                const rel = std.math.cast(u16, value) orelse return error.NumberOverflow;
                if (rel == ir.ANY_RELATION) return error.ReservedRelation;
                return rel;
            },
            .ident => |name| {
                for (self.relations) |binding| {
                    if (std.mem.eql(u8, binding.name, name)) return binding.value;
                }
                return error.UnknownRelation;
            },
            else => return error.UnexpectedToken,
        }
    }

    fn parseDegreeFilter(self: *Parser) ParseError!void {
        try self.expect(.lparen);
        const dir_token = try self.nextToken();
        if (dir_token != .ident) return error.UnexpectedToken;
        const dir = directionByName(dir_token.ident) orelse return error.UnexpectedToken;
        try self.expect(.rparen);

        const cmp: ir.Cmp = switch (try self.nextToken()) {
            .lt => .lt,
            .le => .le,
            .eq_eq => .eq,
            .ge => .ge,
            .gt => .gt,
            else => return error.UnexpectedToken,
        };
        try self.append(.{ .op = .filter_degree, .dir = dir, .cmp = cmp, .arg = try self.natAs(u32) });
    }
};

fn directionByName(name: []const u8) ?ir.Direction {
    if (std.mem.eql(u8, name, "out")) return .out;
    if (std.mem.eql(u8, name, "in")) return .in;
    if (std.mem.eql(u8, name, "both")) return .both;
    return null;
}

fn terminalByName(name: []const u8) ?ir.Op {
    if (std.mem.eql(u8, name, "ids")) return .emit_ids;
    if (std.mem.eql(u8, name, "count")) return .emit_count;
    if (std.mem.eql(u8, name, "exists")) return .emit_exists;
    if (std.mem.eql(u8, name, "edges")) return .emit_edges;
    if (std.mem.eql(u8, name, "csr")) return .emit_csr;
    return null;
}
