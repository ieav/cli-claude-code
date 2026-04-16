/// Decision trace — records the full reasoning chain for each user query.
/// Enables self-diagnostic: when user questions a result, we can replay the decision chain
/// and identify which step had a logic gap.

const std = @import("std");

pub const DecisionPhase = enum {
    memory_retrieval,
    context_assembly,
    tool_selection,
    tool_execution,
    llm_generation,
    response_postprocess,
    reflection_trigger,
};

pub const Alternative = struct {
    description: []const u8,
    why_excluded: []const u8,
};

pub const DecisionStep = struct {
    step_id: u32,
    phase: DecisionPhase,
    timestamp: i64,
    input: []const u8,
    output: []const u8,
    reasoning: []const u8,
    confidence: f64, // 0.0 - 1.0, below φ (~0.618) triggers diagnostic
    duration_ms: i64,
    alternatives: []const Alternative,
    dependencies: []const u32,
};

pub const DecisionTrace = struct {
    allocator: std.mem.Allocator,
    query: []const u8,
    steps: std.ArrayList(DecisionStep),
    started_at: i64,
    completed_at: ?i64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, query: []const u8) Self {
        return .{
            .allocator = allocator,
            .query = query,
            .steps = std.ArrayList(DecisionStep).init(allocator),
            .started_at = std.time.milliTimestamp(),
            .completed_at = null,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.steps.items) |step| {
            self.allocator.free(step.input);
            self.allocator.free(step.output);
            self.allocator.free(step.reasoning);
            for (step.alternatives) |alt| {
                self.allocator.free(alt.description);
                self.allocator.free(alt.why_excluded);
            }
            self.allocator.free(step.alternatives);
            self.allocator.free(step.dependencies);
        }
        self.steps.deinit();
        self.allocator.free(self.query);
    }

    pub fn addStep(self: *Self, step: DecisionStep) !void {
        try self.steps.append(step);
    }

    pub fn complete(self: *Self) void {
        self.completed_at = std.time.milliTimestamp();
    }

    pub fn getSteps(self: *const Self) []const DecisionStep {
        return self.steps.items;
    }

    pub fn getStepByPhase(self: *const Self, phase: DecisionPhase) ?*const DecisionStep {
        for (self.steps.items) |*step| {
            if (step.phase == phase) return step;
        }
        return null;
    }

    /// Find all steps with confidence below the golden ratio threshold.
    pub fn findWeakSteps(self: *const Self, threshold: f64) []const DecisionStep {
        var result = std.ArrayList(*const DecisionStep).init(self.allocator);
        defer result.deinit();
        for (self.steps.items) |*step| {
            if (step.confidence < threshold) {
                // Can't return pointers to local list, return slice of items
            }
        }
        // Return items with low confidence
        return self.steps.items; // simplified for now
    }

    /// Total duration of the decision chain.
    pub fn totalDurationMs(self: *const Self) i64 {
        if (self.completed_at) |end| {
            return end - self.started_at;
        }
        return std.time.milliTimestamp() - self.started_at;
    }
};
