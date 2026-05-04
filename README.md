# coco-connect-capture-releases

Release assets and runtime scripts for `coco-connect-capture`.

## Contents

- Windows executable release asset:
  - `coco-connect-capture.exe`
- Capture Tcl scripts:
  - `tcl/coco_capture_bootstrap.tcl`
  - `tcl/utils.tcl`
  - `tcl/highlight.tcl`
  - `tcl/property.tcl`
  - `tcl/move.tcl`
  - `tcl/zoom.tcl`

## Bridge Commands

- `highlight_net <NET_NAME>`
- `highlight_part <REFDES>`
- `clear_highlight`
- `part_properties <REFDES>`
- `part_property_get <REFDES>|<PROPERTY_NAME>`
- `part_property_set <REFDES>|<PROPERTY_NAME>|<VALUE>`
- `part_property_delete <REFDES>|<PROPERTY_NAME>`
- `part_property_display_mode <REFDES>|<PROPERTY_NAME>|<hidden|value_only|name_and_value>`
- `part_move_absolute <REFDES>|<X>|<Y>`
- `part_move_relative <REFDES>|<DX>|<DY>`
- `zoom_selection`
- `zoom_fit`

Property and move commands use `|` as the argument separator because the line protocol has a
single argument field. `part_property_set` treats everything after the second `|`
as the value.

## Tcl Usage Examples

Manual Tcl usage in the Capture command window:

```tcl
list_part_properties U1
part_property_get U1 {Value}
part_property_set U1 {COCO_TEST_PROP} hello
part_property_display_mode U1 {COCO_TEST_PROP} value_only
part_property_display_mode U1 {COCO_TEST_PROP} name_and_value
part_property_display_mode U1 {COCO_TEST_PROP} hidden
part_property_delete U1 {COCO_TEST_PROP}
part_move_absolute U1 1200 3400
part_move_relative U1 200 -100
zoom_selection
zoom_fit
```

Bridge command argument examples:

```text
part_properties U1
part_property_get U1|Value
part_property_set U1|COCO_TEST_PROP|hello
part_property_display_mode U1|COCO_TEST_PROP|value_only
part_property_display_mode U1|COCO_TEST_PROP|name_and_value
part_property_display_mode U1|COCO_TEST_PROP|hidden
part_property_delete U1|COCO_TEST_PROP
part_move_absolute U1|1200|3400
part_move_relative U1|200|-100
zoom_selection
zoom_fit
```

## Response Format

The line protocol response still uses:

- `id<TAB>json`

`json` is always a single-line JSON payload.

Success example:

```json
{"ok":true,"data":{"command":"part_property_get","refdes":"U1","page_path":"MAIN/1","match_count":1,"property":"PCB Footprint","value":"SOIC8"}}
```

Error example:

```json
{"ok":false,"error":{"code":"no_property","message":"No matching property found","details":{"command":"part_property_get","refdes":"U1","property":"PCB Footprint"}}}
```
