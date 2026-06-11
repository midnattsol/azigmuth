//! Caller-owned columnar property stores.
//!
//! The engine assigns every edge a stable property row id when
//! `GraphOptions.edge_properties` is enabled (`EdgeRef.property_row`,
//! `Graph.addEdgeWithProperties`, `Graph.edgePropertyRow`). Node ids are
//! stable by construction. Columns live OUTSIDE the graph: the schema is
//! whatever set of `EdgeColumn(T)` / `NodeColumn(T)` values the application
//! composes at comptime — the engine never stores property bytes and pays
//! nothing for columns it does not know about.
//!
//! Concurrency contract: column values are plain memory owned by the caller.
//! They are not versioned by the graph's RCU; coordinate concurrent writers
//! and readers of the same column externally. A recycled row (after edge
//! removal + reclaim) retains the previous edge's value until overwritten —
//! set properties when creating edges.

const std = @import("std");

/// Sparse paged array indexed by a stable u32 row/node id. Segments allocate
/// lazily on first `set` within their range; `get` of an untouched row
/// returns `default_value`. Index 0 is the reserved invalid edge row.
pub fn PropertyColumn(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const SEGMENT_LEN: usize = 1024;

        allocator: std.mem.Allocator,
        default_value: T,
        segments: std.ArrayList(?[]T) = .empty,

        pub fn init(allocator: std.mem.Allocator, default_value: T) Self {
            return .{ .allocator = allocator, .default_value = default_value };
        }

        pub fn deinit(self: *Self) void {
            for (self.segments.items) |segment| {
                if (segment) |payload| self.allocator.free(payload);
            }
            self.segments.deinit(self.allocator);
            self.* = undefined;
        }

        fn segmentIndex(row: u32) usize {
            return @as(usize, row) / SEGMENT_LEN;
        }

        fn slotIndex(row: u32) usize {
            return @as(usize, row) % SEGMENT_LEN;
        }

        pub fn set(self: *Self, row: u32, value: T) !void {
            const segment_idx = segmentIndex(row);
            while (self.segments.items.len <= segment_idx) {
                try self.segments.append(self.allocator, null);
            }
            if (self.segments.items[segment_idx] == null) {
                const payload = try self.allocator.alloc(T, SEGMENT_LEN);
                @memset(payload, self.default_value);
                self.segments.items[segment_idx] = payload;
            }
            self.segments.items[segment_idx].?[slotIndex(row)] = value;
        }

        pub fn get(self: *const Self, row: u32) T {
            const segment_idx = segmentIndex(row);
            if (segment_idx >= self.segments.items.len) return self.default_value;
            const segment = self.segments.items[segment_idx] orelse return self.default_value;
            return segment[slotIndex(row)];
        }
    };
}

/// Column indexed by `EdgeRef.property_row`.
pub const EdgeColumn = PropertyColumn;

/// Column indexed by `NodeId.index`.
pub const NodeColumn = PropertyColumn;

const public_graph = @import("api/public_graph.zig");
const types = @import("core/types.zig");

/// Ergonomic comptime-schema wrapper: one graph plus one `EdgeColumn` per
/// schema field, bundled so edge creation and property writes happen
/// together. This closes the recycled-row sharp edge of bare columns:
/// `addEdge` writes EVERY schema field for the new row, so a recycled row can
/// never leak a previous edge's values.
///
/// `Schema` must be a struct whose fields all carry default values:
///
///   const Weights = struct { weight: f32 = 0.0, since: u64 = 0 };
///   var g = try azigmuth.PropertyGraph(Weights).init(allocator, .{});
///   defer g.deinit();
///   const row = try g.addEdge(a, b, 0, .{}, .{ .weight = 1.5, .since = now });
///
/// Everything not property-related is reached through the inner handle
/// (`g.graph`): snapshots, algorithms, repair, validation.
pub fn PropertyGraph(comptime Schema: type) type {
    const schema_info = @typeInfo(Schema);
    if (schema_info != .@"struct") @compileError("PropertyGraph schema must be a struct");
    const schema_fields = schema_info.@"struct".fields;
    if (schema_fields.len == 0) @compileError("PropertyGraph schema must have at least one field");

    comptime var column_names: [schema_fields.len][:0]const u8 = undefined;
    comptime var column_types: [schema_fields.len]type = undefined;
    inline for (schema_fields, 0..) |schema_field, field_idx| {
        column_names[field_idx] = schema_field.name;
        column_types[field_idx] = PropertyColumn(schema_field.type);
    }
    const Columns = @Struct(.auto, null, &column_names, &column_types, &@splat(.{}));

    return struct {
        const Self = @This();

        graph: *public_graph.Graph,
        columns: Columns,

        fn fieldDefault(comptime schema_field: std.builtin.Type.StructField) schema_field.type {
            const ptr = schema_field.default_value_ptr orelse
                @compileError("PropertyGraph schema field '" ++ schema_field.name ++ "' must declare a default value");
            return @as(*const schema_field.type, @ptrCast(@alignCast(ptr))).*;
        }

        /// `options.edge_properties` is forced on — the wrapper is the
        /// property surface.
        pub fn init(allocator: std.mem.Allocator, options: types.GraphOptions) types.GraphError!Self {
            var forced_options = options;
            forced_options.edge_properties = true;
            const graph = try public_graph.Graph.initWithOptions(allocator, forced_options);
            errdefer graph.deinit();

            var columns: Columns = undefined;
            inline for (schema_fields) |schema_field| {
                @field(columns, schema_field.name) =
                    PropertyColumn(schema_field.type).init(allocator, comptime fieldDefault(schema_field));
            }
            return .{ .graph = graph, .columns = columns };
        }

        pub fn deinit(self: *Self) void {
            inline for (schema_fields) |schema_field| {
                @field(self.columns, schema_field.name).deinit();
            }
            self.graph.deinit();
        }

        pub fn addNode(self: *Self) types.GraphError!types.NodeId {
            return self.graph.addNode();
        }

        /// Adds the edge and writes every schema field for its row. If a
        /// column write fails the edge is removed again (best effort), so the
        /// call is all-or-nothing from the caller's perspective.
        pub fn addEdge(
            self: *Self,
            source: types.NodeId,
            destination: types.NodeId,
            relation: u16,
            flags: types.EdgeFlags,
            values: Schema,
        ) types.GraphError!u32 {
            const row = try self.graph.addEdgeWithProperties(source, destination, relation, flags);
            self.setValues(row, values) catch |err| {
                _ = self.graph.removeEdge(source, destination) catch {};
                return err;
            };
            return row;
        }

        pub fn removeEdge(self: *Self, source: types.NodeId, destination: types.NodeId) types.GraphError!bool {
            return self.graph.removeEdge(source, destination);
        }

        /// Writes every schema field for one row.
        pub fn setValues(self: *Self, row: u32, values: Schema) types.GraphError!void {
            inline for (schema_fields) |schema_field| {
                try @field(self.columns, schema_field.name).set(row, @field(values, schema_field.name));
            }
        }

        /// Gathers every schema field for one row (defaults where unset).
        pub fn getValues(self: *const Self, row: u32) Schema {
            var values: Schema = undefined;
            inline for (schema_fields) |schema_field| {
                @field(values, schema_field.name) = @field(self.columns, schema_field.name).get(row);
            }
            return values;
        }

        /// Convenience point lookup: properties of the live edge
        /// (source → destination), or null when no edge matches.
        pub fn edgeValues(self: *const Self, source: types.NodeId, destination: types.NodeId) types.GraphError!?Schema {
            const row = (try self.graph.edgePropertyRow(source, destination)) orelse return null;
            return self.getValues(row);
        }

        /// Direct access to one column, e.g. for bulk scans aligned with
        /// `CsrView.out_rows`.
        pub fn column(self: *Self, comptime field_name: []const u8) *PropertyColumn(@FieldType(Schema, field_name)) {
            return &@field(self.columns, field_name);
        }
    };
}
