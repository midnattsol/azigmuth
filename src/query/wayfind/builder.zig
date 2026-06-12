//! Wayfind comptime builder.
//!
//! Type-level fluent chaining: every method returns a new pipeline *type*
//! whose comptime data is the step array so far; terminals return the
//! finished `ir.Plan` as a comptime constant. The typestate IS the
//! validator at this surface — a malformed pipeline (set op with no
//! source, anything after a terminal) has no method to call, so it does
//! not compile. Runtime-built plans (parser, C ABI) must go through
//! `ir.validate` instead.
//!
//! Zero runtime cost: the resulting `Plan` is rodata.

const ir = @import("ir.zig");

/// Entry point — every pipeline starts with a source.
pub const Query = struct {
    pub fn fromParam(comptime slot: u16) type {
        return Pipe(&[_]ir.Step{.{ .op = .seed_param, .param = slot }});
    }

    pub fn fromNode(comptime node_idx: u32) type {
        return Pipe(&[_]ir.Step{.{ .op = .seed_node, .arg = node_idx }});
    }

    pub fn allNodes() type {
        return Pipe(&[_]ir.Step{.{ .op = .all_nodes }});
    }
};

fn Pipe(comptime steps: []const ir.Step) type {
    return struct {
        // ── Transformations ───────────────────────────────────────────

        pub fn out(comptime rel: u16, comptime hops: ir.Hops) type {
            return expand(.out, rel, hops);
        }

        pub fn in(comptime rel: u16, comptime hops: ir.Hops) type {
            return expand(.in, rel, hops);
        }

        pub fn both(comptime rel: u16, comptime hops: ir.Hops) type {
            return expand(.both, rel, hops);
        }

        /// `out(rel)*` — unbounded closure.
        pub fn outClosure(comptime rel: u16) type {
            return expand(.out, rel, .{ .min = 1, .max = ir.UNBOUNDED });
        }

        pub fn inClosure(comptime rel: u16) type {
            return expand(.in, rel, .{ .min = 1, .max = ir.UNBOUNDED });
        }

        pub fn expand(comptime dir: ir.Direction, comptime rel: u16, comptime hops: ir.Hops) type {
            if (hops.min > hops.max) @compileError("expand: hops.min > hops.max");
            return Pipe(steps ++ &[_]ir.Step{.{ .op = .expand, .dir = dir, .rel = rel, .hops = hops }});
        }

        pub fn filterDegree(comptime dir: ir.Direction, comptime cmp: ir.Cmp, comptime threshold: u32) type {
            return Pipe(steps ++ &[_]ir.Step{.{ .op = .filter_degree, .dir = dir, .cmp = cmp, .arg = threshold }});
        }

        // ── Set operations (parameter operand) ────────────────────────

        pub fn unionParam(comptime slot: u16) type {
            return setOpParam(.set_union, slot);
        }

        pub fn intersectParam(comptime slot: u16) type {
            return setOpParam(.set_intersect, slot);
        }

        pub fn minusParam(comptime slot: u16) type {
            return setOpParam(.set_minus, slot);
        }

        fn setOpParam(comptime op: ir.Op, comptime slot: u16) type {
            return Pipe(steps ++ &[_]ir.Step{
                .{ .op = .seed_param, .param = slot },
                .{ .op = op },
            });
        }

        // ── Terminals ─────────────────────────────────────────────────

        pub fn ids() ir.Plan {
            return finish(.emit_ids);
        }

        pub fn count() ir.Plan {
            return finish(.emit_count);
        }

        pub fn exists() ir.Plan {
            return finish(.emit_exists);
        }

        pub fn edges() ir.Plan {
            return finish(.emit_edges);
        }

        pub fn csr() ir.Plan {
            return finish(.emit_csr);
        }

        fn finish(comptime op: ir.Op) ir.Plan {
            const all = steps ++ &[_]ir.Step{.{ .op = op }};
            return .{ .steps = all, .param_count = paramCount(all) };
        }

        fn paramCount(comptime all: []const ir.Step) u16 {
            comptime var max_slot: u17 = 0;
            inline for (all) |step| {
                if (step.op == .seed_param and step.param + 1 > max_slot) {
                    max_slot = step.param + 1;
                }
            }
            return max_slot;
        }
    };
}
