# Bridge Layer Decisions

**Status as of 2026-04-12**

This document collates all bridge layer architectural decisions for paint.type, including gossamer_emit clarification, channel workaround, and Burble LLM role constraints.

## Decision Tracking

### 1. Gossamer Streaming IPC for Dirty-Rects

**Status**: CONFIRMED

**Decision**: Tile dirty-rect notifications use `gossamer_emit` (streaming IPC system) rather than the 256-slot capability registry.

**Rationale**:
- Command traffic and rendering updates must not interfere
- Real-time rendering performance requires dedicated streaming path
- Capability registry handles command traffic only

**Implementation**:
```
native core → DirtyRingBuffer → channel<TileDirtyRect> → gossamer_emit → frontend
```

**References**:
- CONTEXT.adoc § Architecture → Shell layer
- CONTEXT.adoc § Architecture → Bridge layer

### 2. Channel-Based Workaround for Effect Handlers

**Status**: CONFIRMED (Authoritative Implementation)

**Decision**: Implement three traffic classes as separate typed channels due to incomplete effect-handler lowering in WASM targets.

**Rationale**:
- Ephapax effect-handler lowering in WASM targets incomplete as of 2026-04-12
- Bridge layer cannot block on incomplete compiler features
- Channel-based approach works with current WASM backend capabilities
- Preserves AffineScript's strong typing guarantees

**Traffic Classes**:
1. `channel<BrushCommand>` - Latency-critical (<16ms target)
2. `channel<TileDirtyRect>` - Throughput-oriented (coordinates + version only)
3. `channel<AsyncOperation>` - Background operations

**Implementation Details**:
- No pixel data crosses the bridge
- Dirty-rects contain coordinates and version numbers only
- Frontend accesses pixel data via typed region reference (L12 freshness)
- Full implementation: docs/WASM-EFFECT-HANDLER-WORKAROUND.md

**Migration Path**:
- Monitor Ephapax `.machine_readable/6a2/STATE.a2ml`
- Replace channels with effect handlers when lowering is complete
- Traffic class separation preserved regardless of transport mechanism

**References**:
- CONTEXT.adoc § Critical compiler constraint
- AGENTS.adoc § Common failure modes
- docs/WASM-EFFECT-HANDLER-WORKAROUND.md (comprehensive implementation)

### 3. Burble LLM Role Constraints

**Status**: CONFIRMED

**Decision**: LLM session participant has tier 1 role with `chat_send` capability only - no canvas access.

**Rationale**:
- Security: Prevent unauthorized canvas modifications
- Architecture: LLM provides decision support, not direct execution
- Collaboration: LLM assists with merge conflict resolution strategies

**Capabilities**:
- `speak`, `listen`, `see_presence` (tier 0 baseline)
- `chat_send` (tier 1 addition)
- **No**: `hand_raise`, `mute_self`, `CanvasSurface` capability token

**Primary Actions**:
- Merge conflict proposal (strategy suggestion only)
- Session context maintenance (decisions, intent, unresolved items)
- Direct question answering in session channel
- Session summary generation

**Implementation**:
- BoJ NeSy+Agent cartridge ordered at session open
- Order ticket format: Scheme (written to BoJ at session open)
- Boundary types: `NeuroSymbolicHandle`, `AgentSession`, `CollaborationContext`
- `CanvasBridge` proven-server type not used

**References**:
- CONTEXT.adoc § Architecture → Collaboration layer
- SPEC-PROTOCOL.adoc § llm-channel.bop
- AGENTS.adoc § Common failure modes → "LLM participant has canvas capability"

## Decision Matrix

| Decision | Status | Implementation | Migration Path |
|----------|--------|----------------|-----------------|
| Gossamer streaming IPC | CONFIRMED | `gossamer_emit` for dirty-rects | None (permanent) |
| Channel workaround | CONFIRMED | Three typed channels | Effect handlers when ready |
| Burble LLM constraints | CONFIRMED | Tier 1, no canvas access | None (permanent) |

## Change Log

### 2026-04-12 - Initial Decisions
- All three decisions confirmed as authoritative
- Channel workaround documentation completed
- Integration with paint.type architecture verified

### Future Updates
- Channel → Effect handler migration: When Ephapax STATE.a2ml confirms completion
- Performance optimizations: As metrics are gathered from real-world usage
- Additional traffic classes: Only if new requirements emerge (unlikely)

## Verification Checklist

Use this checklist when implementing or modifying bridge layer code:

- [ ] Dirty-rects use `gossamer_emit`, not capability registry
- [ ] Three traffic classes remain on separate typed channels
- [ ] No pixel data crosses the bridge
- [ ] Dirty-rect path: native core → DirtyRingBuffer → channel → gossamer_emit → frontend
- [ ] Brush command latency <16ms
- [ ] LLM participant has no canvas capability token
- [ ] BoJ order ticket written correctly at session open
- [ ] All SPDX headers present
- [ ] No banned languages or patterns used

## Status Definitions

**CONFIRMED**: Decision is authoritative and implemented. Do not change without project-wide discussion.

**PENDING**: Decision is proposed but not yet implemented or ratified.

**DEPRECATED**: Decision has been superseded by a newer approach.

## Related Documents

- `CONTEXT.adoc` - Overall project context and architecture
- `SPEC-ABI.adoc` - Authoritative typed-wasm region schemas
- `SPEC-PROTOCOL.adoc` - Network-facing message schemas
- `AGENTS.adoc` - Coding AI constraints and common failure modes
- `docs/WASM-EFFECT-HANDLER-WORKAROUND.md` - Comprehensive channel implementation

## Maintenance

This document is maintained as part of the bridge layer. Updates require:
1. Discussion in project channels
2. Reference to authoritative sources (CONTEXT.adoc, SPEC files)
3. Status change rationale documented
4. Verification checklist updated if needed