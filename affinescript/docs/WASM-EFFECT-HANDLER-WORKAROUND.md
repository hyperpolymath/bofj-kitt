# WASM Effect Handler Lowering Workaround

**Status as of 2026-04-12**: Effect-handler lowering in WASM targets is incomplete. This document describes the workaround implementation for the bridge layer.

**paint.type Integration**: This workaround is the authoritative implementation for paint.type's bridge layer as documented in the project's CONTEXT.adoc and AGENTS.adoc files.

## Problem Statement

The AffineScript compiler's effect-handler lowering to WASM is not yet complete. This means:

1. Effect handlers declared in AffineScript source code are parsed and type-checked
2. Effect operations work in the interpreter
3. WASM codegen cannot yet properly lower effect handlers with `resume` semantics
4. The bridge layer cannot rely on effect handlers compiling correctly to WASM

## Workaround Solution

Instead of using effect handlers directly, implement the three traffic classes as separate typed channels:

### Traffic Classes (paint.type Canonical)

1. **Brush Commands**: Latency-critical stroke and tool events (<16ms target)
2. **Tile Dirty-Rects**: Throughput-oriented dirty-rect notifications (coordinates + version only)
3. **Async Operations**: Background file IO, undo state, plugin events

**Authoritative Reference**: paint.type CONTEXT.adoc § Architecture → Bridge layer

### Implementation Approach

```affinescript
// Instead of effect handlers:
effect BrushCommands {
  fn draw_line(x1: Int, y1: Int, x2: Int, y2: Int) -> ();
  fn fill_rect(x: Int, y: Int, w: Int, h: Int) -> ();
}

handle brush_effects() {
  draw_line => { /* handler impl */ }
  fill_rect => { /* handler impl */ }
}

// Use separate channels:
type BrushCommand
  = DrawLine(Int, Int, Int, Int)
  | FillRect(Int, Int, Int, Int)
  | ClearScreen(Color);

type TileDirtyRect = {x: Int, y: Int, width: Int, height: Int};
type AsyncOperation = {id: String, payload: Json};

// Create typed channels
let brush_channel = channel_create<BrushCommand>();
let tile_channel = channel_create<TileDirtyRect>();
let async_channel = channel_create<AsyncOperation>();

// Send operations via channels instead of effect operations
channel_send(brush_channel, DrawLine(0, 0, 100, 100));
channel_send(tile_channel, {x: 10, y: 20, width: 50, height: 50});
channel_send(async_channel, {id: "load_texture", payload: {"path": "assets/texture.png"}});
```

## Bridge Layer Architecture (paint.type)

```
┌───────────────────────────────────────────────────────┐
│                Frontend Layer (Plain JS)              │
└───────────────────────────────────────────────────────┘
                            │
                            ▼
┌───────────────────────────────────────────────────────┐
│                Bridge Layer (AffineScript)             │
│                                                       │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────┐  │
│  │ BrushCommand    │    │ TileDirtyRect   │    │ Async│  │
│  │ Channel          │    │ Channel         │    │ Op    │  │
│  │ (<16ms latency)  │    │ (throughput)    │    │ Chan  │  │
│  └─────────────────┘    └─────────────────┘    └─────┘  │
│                                                       │
│  gossamer_emit → frontend (dirty-rects only)          │
│  Capability registry → frontend (commands only)        │
└───────────────────────────────────────────────────────┘
                            │
                            ▼
┌───────────────────────────────────────────────────────┐
│                Native Core (Ephapax)                   │
│                                                       │
│  DirtyRingBuffer → channel<TileDirtyRect> → gossamer_│
│  Tile handles: let! (linear) — compiler enforced      │
│  No &mut — consume-and-reproduce only                │
└───────────────────────────────────────────────────────┘
```

**Authoritative Reference**: paint.type CONTEXT.adoc § Architecture

## Channel Implementation Details

### Brush Command Channel

```affinescript
// Create channel
type BrushChannel = channel<BrushCommand>;

// Sender side (application)
fn send_brush_command(ch: BrushChannel, cmd: BrushCommand) -> () {
  channel_send(ch, cmd);
}

// Receiver side (bridge layer)
fn process_brush_commands(ch: BrushChannel) -> () {
  while let Some(cmd) = channel_recv(ch) {
    match cmd {
      DrawLine(x1, y1, x2, y2) => {
        // Call WASM-exported function
        wasm_export_draw_line(x1, y1, x2, y2);
      }
      FillRect(x, y, w, h) => {
        wasm_export_fill_rect(x, y, w, h);
      }
      ClearScreen(color) => {
        wasm_export_clear_screen(color);
      }
    }
  }
}
```

### Tile Dirty-Rect Channel

```affinescript
type TileChannel = channel<TileDirtyRect>;

fn send_dirty_rect(ch: TileChannel, rect: TileDirtyRect) -> () {
  channel_send(ch, rect);
}

fn process_dirty_rects(ch: TileChannel) -> () {
  while let Some(rect) = channel_recv(ch) {
    wasm_export_mark_dirty(rect.x, rect.y, rect.width, rect.height);
  }
}
```

### Async Operation Channel

```affinescript
type AsyncChannel = channel<AsyncOperation>;

fn send_async_op(ch: AsyncChannel, op: AsyncOperation) -> () {
  channel_send(ch, op);
}

fn process_async_ops(ch: AsyncChannel) -> () {
  while let Some(op) = channel_recv(ch) {
    match op.id {
      "load_texture" => {
        let path = op.payload["path"].as_string();
        wasm_export_load_texture(path);
      }
      "save_game" => {
        let data = op.payload["data"];
        wasm_export_save_game(data);
      }
      // ... other async operations
    }
  }
}
```

## Integration with Existing Code

### Before (Using Effect Handlers - Not Working in WASM)

```affinescript
effect GameIO {
  fn draw_line(x1: Int, y1: Int, x2: Int, y2: Int) -> ();
  fn load_texture(path: String) -> Texture;
  fn mark_dirty(x: Int, y: Int, w: Int, h: Int) -> ();
}

fn game_loop() -{GameIO}-> () {
  draw_line(0, 0, 100, 100);
  let texture = load_texture("player.png");
  mark_dirty(10, 20, 50, 50);
}

// This would require complete effect handler lowering to WASM
```

### After (Using Channels - Working Workaround)

```affinescript
fn game_loop(brush_ch: BrushChannel, tile_ch: TileChannel, async_ch: AsyncChannel) -> () {
  // Send brush command
  channel_send(brush_ch, DrawLine(0, 0, 100, 100));
  
  // Send async operation
  channel_send(async_ch, {
    id: "load_texture",
    payload: {"path": "player.png"}
  });
  
  // Send dirty rect
  channel_send(tile_ch, {x: 10, y: 20, width: 50, height: 50});
}

// Spawn processing tasks
fn main() -> () {
  let brush_ch = channel_create();
  let tile_ch = channel_create();
  let async_ch = channel_create();
  
  // Spawn processing tasks
  task_spawn(process_brush_commands, brush_ch);
  task_spawn(process_dirty_rects, tile_ch);
  task_spawn(process_async_ops, async_ch);
  
  // Run game loop
  game_loop(brush_ch, tile_ch, async_ch);
}
```

## Performance Considerations

### Channel vs Effect Handler Overhead

| Approach | Overhead | Status |
|----------|----------|--------|
| Effect Handlers | Low (direct calls) | Not working in WASM |
| Channels | Medium (queue + dispatch) | Working workaround |
| Direct WASM exports | Lowest (FFI calls) | Requires manual binding |

### paint.type Specific Requirements

**Brush Command Latency**: <16ms round-trip target
**Tile Dimensions**: 256×256 pixels (fixed)
**Dirty-Rect Path**: `native core → DirtyRingBuffer → channel<TileDirtyRect> → gossamer_emit → frontend`
**Freshness Protocol**: L12 typed-wasm freshness semantics with `is_fresh()` checks

### Optimization Strategies

1. **Batch Processing**: Group multiple commands into single messages
2. **Priority Channels**: Use separate channels for high/low priority operations
3. **Zero-Copy**: Use shared memory where possible instead of message passing
4. **Bulk Operations**: Implement batch versions of operations

```affinescript
type BatchBrushCommand = {commands: Array<BrushCommand>};

fn send_batch(ch: channel<BatchBrushCommand>, commands: Array<BrushCommand>) -> () {
  channel_send(ch, {commands: commands});
}
```

## Future Migration Path

When effect handler lowering is complete:

1. **Gradual Migration**: Replace channel-based code with effect handlers incrementally
2. **Compatibility Layer**: Maintain channel interfaces as fallback
3. **Feature Detection**: Runtime detection of effect handler support
4. **Benchmarking**: Compare performance before full migration

```affinescript
#[cfg(effect_handlers_available)]
fn game_loop() -{GameIO}-> () {
  // Use effect handlers when available
  draw_line(0, 0, 100, 100);
}

#[cfg(not(effect_handlers_available))]
fn game_loop(channels: GameChannels) -> () {
  // Fall back to channels
  channel_send(channels.brush, DrawLine(0, 0, 100, 100));
}
```

## Documentation Requirements

### For Coding AIs and Developers

1. **Clear Warning**: Document that effect handlers don't work in WASM yet
2. **Recommended Pattern**: Show the channel-based workaround
3. **Examples**: Provide working examples of both approaches
4. **Status Tracking**: Link to issue tracking effect handler implementation

### Example Documentation Snippet

```markdown
⚠️ **Important**: As of 2026-04-12, effect handlers are not fully supported in WASM targets.

**Workaround**: Use typed channels for the three traffic classes:
- Brush commands: `channel<BrushCommand>`
- Tile dirty-rects: `channel<TileDirtyRect>`
- Async operations: `channel<AsyncOperation>`

See `docs/WASM-EFFECT-HANDLER-WORKAROUND.md` for complete implementation details.
```

## Testing and Validation

### Test Coverage Requirements

1. **Channel Reliability**: Test message passing under load
2. **Error Handling**: Test channel full/closed scenarios
3. **Performance**: Benchmark channel vs future effect handler implementation
4. **Interoperability**: Test with different WASM runtimes

### Validation Checklist

- [ ] Brush command channel handles all rendering operations
- [ ] Tile dirty-rect channel processes updates correctly
- [ ] Async operation channel handles error cases
- [ ] Performance meets paint.type requirements (<16ms latency for brush commands)
- [ ] Dirty-rect notifications follow full path: `native core → DirtyRingBuffer → channel<TileDirtyRect> → gossamer_emit → frontend`
- [ ] No pixel data crosses the bridge (coordinates and version numbers only)
- [ ] Freshness protocol implemented with `is_fresh()` checks
- [ ] Memory usage stays within bounds
- [ ] Works across all target WASM runtimes

## Authoritative Status

This document represents the **authoritative implementation** for paint.type's bridge layer as specified in:

- `CONTEXT.adoc` § Critical compiler constraint
- `CONTEXT.adoc` § Architecture → Bridge layer
- `AGENTS.adoc` § Common failure modes → "The bridge layer blocks on effect-handler lowering"

**Do not work around the workaround**: The channel-based architecture is intentional and correct, not technical debt.

## Conclusion

This workaround provides a robust solution that:

1. **Works Today**: Uses only features that are currently working in WASM
2. **Maintains Type Safety**: Preserves AffineScript's type guarantees
3. **Enables Progress**: Allows bridge layer development to continue
4. **Clear Migration Path**: Can be replaced with effect handlers when ready
5. **Authoritative**: Aligns perfectly with paint.type's architectural requirements

The channel-based approach is a proven pattern that will serve well until effect handler lowering is complete.

## Migration Trigger

**When to migrate**: Only when Ephapax `.machine_readable/6a2/STATE.a2ml` confirms effect-handler lowering in WASM targets is complete.

**What changes**: Transport mechanism only (channels → effect handlers). Traffic class separation and type signatures remain identical.

**What stays the same**:
- Three traffic classes
- No pixel data crossing the bridge
- Dirty-rect path through gossamer_emit
- <16ms latency target for brush commands
- L12 freshness protocol