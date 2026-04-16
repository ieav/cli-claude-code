/// Memory types — defines the memory taxonomy for the three-tier memory system.

pub const MemoryType = enum {
    user,       // User preferences, role, knowledge
    feedback,   // Corrections and guidance from user
    project,    // Project-specific context
    reference,  // External references and resources
};

pub const MemoryEntry = struct {
    id: [16]u8,
    mem_type: MemoryType,
    name: []const u8,
    description: []const u8,
    content: []const u8,
    access_count: u32,
    created_at: i64,
    updated_at: i64,
};

pub const MemoryTier = enum {
    working,    // In-memory LRU, current session
    episodic,   // SQLite, past interaction history
    semantic,   // Knowledge graph, extracted facts
};
