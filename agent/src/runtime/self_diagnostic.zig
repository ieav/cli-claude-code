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
        var gaps = std.ArrayList(LogicGap).init(self.allocator);
        defer gaps.deinit();

        var weakest_confidence: f64 = 1.0;
        var weakest_step: ?u32 = null;

        // Analyze each step for gaps
        for (trace.getSteps()) |step| {
            // Check 1: Confidence below φ threshold
            if (step.confidence < math.constants.PHI) {
                try gaps.append(.{
                    .step_id = step.step_id,
                    .phase = step.phase,
                    .gap_type = .insufficient_depth,
                    .description = try std.fmt.allocPrint(self.allocator,
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
                try gaps.append(.{
                    .step_id = step.step_id,
                    .phase = step.phase,
                    .gap_type = .wrong_decision,
                    .description = try std.fmt.allocPrint(self.allocator,
                        "Phase {s} took {d}ms (suspiciously long)",
                        .{ @tagName(step.phase), step.duration_ms },
                    ),
                    .severity = 0.5,
                });
            }

            // Check 3: Empty output suggests a gap
            if (step.output.len == 0 and step.input.len > 0) {
                try gaps.append(.{
                    .step_id = step.step_id,
                    .phase = step.phase,
                    .gap_type = .context_lost,
                    .description = try std.fmt.allocPrint(self.allocator,
                        "Phase {s} produced no output despite having input",
                        .{@tagName(step.phase)},
                    ),
                    .severity = 0.8,
                });
            }
        }

        // Find root cause (highest severity gap)
        var root_cause: ?*const LogicGap = null;
        var max_severity: f64 = 0;
        for (gaps.items) |*g| {
            if (g.severity > max_severity) {
                max_severity = g.severity;
                root_cause = g;
            }
        }

        // Generate suggestions based on gaps
        var suggestions = std.ArrayList(ImprovementSuggestion).init(self.allocator);
        defer suggestions.deinit();

        if (gaps.items.len > 0) {
            for (gaps.items) |gap| {
                switch (gap.gap_type) {
                    .insufficient_depth => {
                        try suggestions.append(.{
                            .for_phase = gap.phase,
                            .suggestion = "增加该阶段的信息检索范围",
                            .auto_applicable = true,
                            .impact_score = 0.7,
                        });
                    },
                    .context_lost => {
                        try suggestions.append(.{
                            .for_phase = gap.phase,
                            .suggestion = "检查上下文传递是否有断裂",
                            .auto_applicable = false,
                            .impact_score = 0.9,
                        });
                    },
                    .wrong_decision => {
                        try suggestions.append(.{
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

        // Own the slices
        const owned_gaps = try self.allocator.dupe(LogicGap, gaps.items);
        const owned_suggestions = try self.allocator.dupe(ImprovementSuggestion, suggestions.items);

        return DiagnosisReport{
            .user_concern = user_concern,
            .identified_gaps = owned_gaps,
            .root_cause = root_cause,
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
        .input = "query",
        .output = "results",
        .reasoning = "searched memory",
        .confidence = 0.3, // Below φ
        .duration_ms = 100,
        .alternatives = &.{},
        .dependencies = &.{},
    });

    try trace.addStep(.{
        .step_id = 2,
        .phase = .llm_generation,
        .timestamp = 0,
        .input = "context",
        .output = "response",
        .reasoning = "generated",
        .confidence = 0.9,
        .duration_ms = 200,
        .alternatives = &.{},
        .dependencies = &.{1},
    });

    trace.complete();
    const report = try diag.diagnose(&trace, "why did you miss X?");
    defer allocator.free(report.identified_gaps);
    defer allocator.free(report.suggestions);

    try std.testing.expect(report.identified_gaps.len >= 1);
    try std.testing.expect(report.root_cause != null);
    try std.testing.expectEqual(@as(u32, 1), report.root_cause.?.step_id);
}
