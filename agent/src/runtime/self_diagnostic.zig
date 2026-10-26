/// Self-diagnostic engine — traces decision chains and identifies logic gaps.
const std = @import("std");
const math = @import("../math/mod.zig");
const decision_trace = @import("decision_trace.zig");

pub const LogicGap = struct {
    step_id: u32,
    phase: decision_trace.DecisionPhase,
    gap_type: GapType,
    description: []const u8,
    severity: f64, // 0-1, below φ = likely root cause
};

pub const GapType = enum {
    missing_information,
    wrong_decision,
    skipped_step,
    insufficient_depth,
    context_lost,
    tool_misuse,
    memory_miss,
};

pub const ImprovementSuggestion = struct {
    for_phase: decision_trace.DecisionPhase,
    suggestion: []const u8,
    auto_applicable: bool,
    impact_score: f64,
};

pub const DiagnosisReport = struct {
    user_concern: []const u8,
    identified_gaps: []const LogicGap,
    root_cause: ?*const LogicGap,
    suggestions: []const ImprovementSuggestion,
    trace_summary: TraceSummary,

    /// Free the heap-owned parts. Suggestion strings are static literals.
    pub fn free(self: @This(), allocator: std.mem.Allocator) void {
        for (self.identified_gaps) |g| allocator.free(g.description);
        allocator.free(self.identified_gaps);
        allocator.free(self.suggestions);
    }
};

pub const TraceSummary = struct {
    total_steps: usize,
    total_duration_ms: i64,
    weakest_step: ?u32,
    weakest_confidence: f64,
};

pub const SelfDiagnostic = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Diagnose a decision trace based on user concern.
    pub fn diagnose(
        self: *Self,
        trace: *const decision_trace.DecisionTrace,
        user_concern: []const u8,
    ) !DiagnosisReport {
        var gaps = std.ArrayList(LogicGap).empty;
        defer gaps.deinit(self.allocator);

        var weakest_confidence: f64 = 1.0;
        var weakest_step: ?u32 = null;

        // Analyze each step for gaps
        for (trace.getSteps()) |step| {
            // Check 1: Confidence below φ threshold
            if (step.confidence < math.constants.PHI) {
                try gaps.append(self.allocator, .{
                    .step_id = step.step_id,
                    .phase = step.phase,
                    .gap_type = .insufficient_depth,
                    .description = try self.allocator.print(
                        "Phase {s} (step {d}) confidence {d:.3} below φ={d:.3}",
                        .{ @tagName(step.phase), step.step_id, step.confidence, math.constants.PHI },
                    ),
                    .severity = 1.0 - step.confidence,
                });
            }

            // Track weakest step
            if (step.confidence < weakest_confidence) {
                weakest_confidence = step.confidence;
                weakest_step = step.step_id;
            }

            // Check 2: Very long duration may indicate stuck/inefficient
            if (step.duration_ms > 30_000) {
                try gaps.append(self.allocator, .{
                    .step_id = step.step_id,
                    .phase = step.phase,
                    .gap_type = .wrong_decision,
                    .description = try self.allocator.print(
                        "Phase {s} took {d}ms (suspiciously long)",
                        .{ @tagName(step.phase), step.duration_ms },
                    ),
                    .severity = 0.5,
                });
            }

            // Check 3: Empty output suggests a gap
            if (step.output.len == 0 and step.input.len > 0) {
                try gaps.append(self.allocator, .{
                    .step_id = step.step_id,
                    .phase = step.phase,
                    .gap_type = .context_lost,
                    .description = try self.allocator.print(
                        "Phase {s} produced no output despite having input",
                        .{@tagName(step.phase)},
                    ),
                    .severity = 0.8,
                });
            }
        }

        // Find root cause (highest severity gap). Track the index: a pointer
        // into gaps.items would dangle once the list is freed.
        var root_cause_idx: ?usize = null;
        var max_severity: f64 = 0;
        for (gaps.items, 0..) |*g, i| {
            if (g.severity > max_severity) {
                max_severity = g.severity;
                root_cause_idx = i;
            }
        }

        // Generate suggestions based on gaps
        var suggestions = std.ArrayList(ImprovementSuggestion).empty;
        defer suggestions.deinit(self.allocator);

        if (gaps.items.len > 0) {
            for (gaps.items) |gap| {
                switch (gap.gap_type) {
                    .insufficient_depth => {
                        try suggestions.append(self.allocator, .{
                            .for_phase = gap.phase,
                            .suggestion = "增加该阶段的信息检索范围",
                            .auto_applicable = true,
                            .impact_score = 0.7,
                        });
                    },
                    .context_lost => {
                        try suggestions.append(self.allocator, .{
                            .for_phase = gap.phase,
                            .suggestion = "检查上下文传递是否有断裂",
                            .auto_applicable = false,
                            .impact_score = 0.9,
                        });
                    },
                    .wrong_decision => {
                        try suggestions.append(self.allocator, .{
                            .for_phase = gap.phase,
                            .suggestion = "检查工具选择逻辑",
                            .auto_applicable = false,
                            .impact_score = 0.6,
                        });
                    },
                    else => {},
                }
            }
        }

        // Own the slices. Deep-copy gap descriptions first — a shallow dupe
        // would leave owned_gaps pointing at the strings freed below. Only
        // the filled prefix may be freed on the error path.
        const owned_gaps = try self.allocator.alloc(LogicGap, gaps.items.len);
        var filled: usize = 0;
        errdefer for (owned_gaps[0..filled]) |g| self.allocator.free(g.description);
        for (gaps.items, 0..) |g, i| {
            owned_gaps[i] = g;
            owned_gaps[i].description = try self.allocator.dupe(u8, g.description);
            filled = i + 1;
        }
        for (gaps.items) |g| self.allocator.free(g.description);
        const owned_suggestions = try self.allocator.dupe(ImprovementSuggestion, suggestions.items);

        return DiagnosisReport{
            .user_concern = user_concern,
            .identified_gaps = owned_gaps,
            .root_cause = if (root_cause_idx) |i| &owned_gaps[i] else null,
            .suggestions = owned_suggestions,
            .trace_summary = .{
                .total_steps = trace.getSteps().len,
                .total_duration_ms = trace.totalDurationMs(),
                .weakest_step = weakest_step,
                .weakest_confidence = weakest_confidence,
            },
        };
    }
};

test "SelfDiagnostic identifies low confidence steps" {
    const allocator = std.testing.allocator;
    var diag = SelfDiagnostic.init(allocator);

    var trace = decision_trace.DecisionTrace.init(allocator, try allocator.dupe(u8, "test query"));
    defer trace.deinit();

    try trace.addStep(.{
        .step_id = 1,
        .phase = .memory_retrieval,
        .timestamp = 0,
        .input = try allocator.dupe(u8, "query"),
        .output = try allocator.dupe(u8, "results"),
        .reasoning = try allocator.dupe(u8, "searched memory"),
        .confidence = 0.3, // Below φ
        .duration_ms = 100,
        .alternatives = &.{},
        .dependencies = &.{},
    });

    try trace.addStep(.{
        .step_id = 2,
        .phase = .llm_generation,
        .timestamp = 0,
        .input = try allocator.dupe(u8, "context"),
        .output = try allocator.dupe(u8, "response"),
        .reasoning = try allocator.dupe(u8, "generated"),
        .confidence = 0.9,
        .duration_ms = 200,
        .alternatives = &.{},
        .dependencies = try allocator.dupe(u32, &.{1}),
    });

    trace.complete();
    const report = try diag.diagnose(&trace, "why did you miss X?");
    defer report.free(allocator);

    try std.testing.expect(report.identified_gaps.len >= 1);
    try std.testing.expect(report.root_cause != null);
    try std.testing.expectEqual(@as(u32, 1), report.root_cause.?.step_id);
}
