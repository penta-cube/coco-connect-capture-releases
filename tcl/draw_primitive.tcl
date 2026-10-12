# coco-connect-capture draw_primitive bridge implementation (cable drawing, C1).
#
# Places ONE low-level drawing primitive on the active page: wire, rectangle,
# line or comment text. This is the creation primitive the cable drawing layer
# builds on; it does no layout of its own.
#
# Drawing goes through Capture's high-level Tcl commands (PlaceWire /
# PlaceRectangle / PlaceLine / PlaceText), which take millimetres on a metric
# page. The DB stores coordinates as integers of 0.01 inch (0.254 mm) and does
# NOT snap to the grid -- each mm value is rounded independently, so callers
# that need wire ends to meet should keep coordinates on a shared 0.254 mm
# lattice (2.54 mm grid = 10 DB units).
#
# Only metric pages are accepted: on an inch page the same numbers would be
# read in another unit, so the call is refused rather than guessed.
#
# There is no rollback for created objects. dry_run (default) validates and
# returns the plan; apply places the object and reports how many objects of
# that class appeared on the page (before/after count), plus the stored DB
# endpoints for a wire.

namespace eval ::draw_primitive {
    variable MM_PER_DB_UNIT 0.254
    variable KINDS {wire rect line text}
}

proc ::draw_primitive::_fail {code message {extra {}}} {
    set pairs [list [::coco_capture_utils::json_field_string command "draw_primitive"]]
    foreach {k v} $extra {
        lappend pairs [::coco_capture_utils::json_field_string $k $v]
    }
    error [::coco_capture_utils::json_error $code $message \
        [::coco_capture_utils::json_object_from_pairs $pairs]]
}

proc ::draw_primitive::_active_page {} {
    if {![::coco_capture_utils::cmd_exists GetActivePage]} {
        _fail "no_active_page" "GetActivePage is not available"
    }
    if {[catch {set page [GetActivePage]}] || [::coco_capture_utils::is_null $page]} {
        _fail "no_active_page" "open the target schematic page and make it active"
    }
    return $page
}

# Page size in mm. Metric pages report width/height in 1/1000 mm.
proc ::draw_primitive::_page_size_mm {page} {
    set metric 0
    catch {set metric [$page GetIsMetric]}
    if {!$metric} {
        _fail "page_not_metric" \
            "drawing needs a metric page (Options > Schematic Page Properties > Units: Millimeters)"
    }
    if {[catch {set w [$page GetPageWidth]}] || [catch {set h [$page GetPageHeight]}]} {
        _fail "page_size_unavailable" "cannot read page width/height"
    }
    return [list [expr {$w / 1000.0}] [expr {$h / 1000.0}]]
}

proc ::draw_primitive::_to_db {mm} {
    variable MM_PER_DB_UNIT
    return [expr {int(round($mm / $MM_PER_DB_UNIT))}]
}

proc ::draw_primitive::_validate {kind x1 y1 x2 y2 style width text page_w page_h} {
    variable KINDS
    if {[lsearch -exact $KINDS $kind] < 0} {
        _fail "invalid_arg" "kind must be one of: [join $KINDS {, }]" [list kind $kind]
    }
    foreach {name v} [list x1 $x1 y1 $y1 x2 $x2 y2 $y2] {
        # Plain decimals only: they are echoed into JSON and passed to Place*.
        if {![regexp {^-?[0-9]+(\.[0-9]+)?$} $v]} {
            _fail "invalid_arg" "$name must be a decimal number in mm" [list $name $v]
        }
    }
    foreach {name v limit} [list x1 $x1 $page_w x2 $x2 $page_w y1 $y1 $page_h y2 $y2 $page_h] {
        if {$v < 0 || $v > $limit} {
            _fail "out_of_bounds" "$name=$v mm is outside the page (0..$limit mm)" [list $name $v]
        }
    }
    switch -- $kind {
        wire - line {
            if {[_to_db $x1] == [_to_db $x2] && [_to_db $y1] == [_to_db $y2]} {
                _fail "invalid_arg" "$kind has zero length after rounding to DB units"
            }
        }
        rect - text {
            if {[_to_db $x1] == [_to_db $x2] || [_to_db $y1] == [_to_db $y2]} {
                _fail "invalid_arg" "$kind needs non-zero width and height"
            }
        }
    }
    if {$kind eq "text" && [string trim $text] eq ""} {
        _fail "invalid_arg" "text is required for kind=text"
    }
    if {$style ne "" && ($kind eq "wire" || $kind eq "text")} {
        _fail "invalid_arg" "line_style applies to rect/line only"
    }
    if {$width ne "" && ($kind eq "wire" || $kind eq "text")} {
        _fail "invalid_arg" "line_width applies to rect/line only"
    }
    if {$style ne "" && (![string is integer -strict $style] || $style < 0 || $style > 4)} {
        _fail "invalid_arg" "line_style must be an integer 0..4" [list line_style $style]
    }
    if {$width ne "" && (![string is integer -strict $width] || $width < 0 || $width > 3)} {
        _fail "invalid_arg" "line_width must be an integer 0..3" [list line_width $width]
    }
}

# Wires live in the page wire list; rect/line/text are comment graphics.
proc ::draw_primitive::_collect {page kind status} {
    if {$kind eq "wire"} {
        set new_m NewWiresIter; set next_m NextWire; set del delete_DboPageWiresIter
    } else {
        set new_m NewCommentGraphicsIter; set next_m NextCommentGraphic
        set del delete_DboPageCommentGraphicsIter
    }
    set objs {}
    if {[catch {set it [$page $new_m $status]}]} { return {} }
    while {1} {
        if {[catch {set obj [$it $next_m $status]}]} { break }
        if {[::coco_capture_utils::is_null $obj]} { break }
        lappend objs $obj
    }
    ::coco_capture_utils::safe_delete $del $it
    return $objs
}

proc ::draw_primitive::_ids {objs status} {
    set ids [dict create]
    foreach obj $objs {
        set oid [::coco_capture_utils::id $obj $status]
        if {$oid ne ""} { dict set ids $oid 1 }
    }
    return $ids
}

proc ::draw_primitive::_point_json {key pt} {
    set x [DboTclHelper_sGetCPointX $pt]
    set y [DboTclHelper_sGetCPointY $pt]
    return [::coco_capture_utils::json_field_json $key \
        [::coco_capture_utils::json_object_from_pairs [list \
            [::coco_capture_utils::json_field_number x $x] \
            [::coco_capture_utils::json_field_number y $y]]]]
}

proc ::draw_primitive::_wire_json {wire status} {
    set pairs {}
    if {![catch {set a [$wire GetStartPoint $status]}]} { lappend pairs [_point_json start $a] }
    if {![catch {set b [$wire GetEndPoint $status]}]} { lappend pairs [_point_json end $b] }
    return [::coco_capture_utils::json_object_from_pairs $pairs]
}

# Comment text placed by PlaceText needs its bounding box recomputed, the same
# getter chain used for editing existing comment text.
proc ::draw_primitive::_finish_text {x y} {
    if {[catch {SelectObject $x $y FALSE}]} { return }
    if {[catch {set sel [GetSelectedObjects]}] || [::coco_capture_utils::is_null $sel]} { return }
    if {[catch {set ti [DboGraphicInstanceToDboGraphicCommentTextInst $sel]}]} { return }
    if {[::coco_capture_utils::is_null $ti]} { return }
    if {[catch {set td [$ti GetDboCommentText]}] || [::coco_capture_utils::is_null $td]} { return }
    catch {$td SetRecalBoundingBox}
    catch {$ti MarkModified}
}

proc ::draw_primitive::_place {kind x1 y1 x2 y2 style width text} {
    catch {UnSelectAll}
    switch -- $kind {
        wire { PlaceWire $x1 $y1 $x2 $y2 }
        rect { PlaceRectangle $x1 $y1 $x2 $y2 }
        line { PlaceLine $x1 $y1 $x2 $y2 }
        text { PlaceText $x1 $y1 $x2 $y2 $text }
    }
    # Freshly placed graphics stay selected, so style setters apply to them.
    if {$style ne ""} { SetLineStyle $style }
    if {$width ne ""} { SetLineWidth $width }
    if {$kind eq "text"} { _finish_text $x1 $y1 }
    catch {UnSelectAll}
}

proc ::draw_primitive::draw {kind mode x1 y1 x2 y2 style width text} {
    set apply [expr {$mode eq "apply"}]
    set page [_active_page]
    lassign [_page_size_mm $page] page_w page_h
    _validate $kind $x1 $y1 $x2 $y2 $style $width $text $page_w $page_h

    set status [::coco_capture_utils::status]
    set page_name [::coco_capture_utils::name $page]

    set coords [::coco_capture_utils::json_object_from_pairs [list \
        [::coco_capture_utils::json_field_number x1 $x1] \
        [::coco_capture_utils::json_field_number y1 $y1] \
        [::coco_capture_utils::json_field_number x2 $x2] \
        [::coco_capture_utils::json_field_number y2 $y2]]]
    set expected_db [::coco_capture_utils::json_object_from_pairs [list \
        [::coco_capture_utils::json_field_number x1 [_to_db $x1]] \
        [::coco_capture_utils::json_field_number y1 [_to_db $y1]] \
        [::coco_capture_utils::json_field_number x2 [_to_db $x2]] \
        [::coco_capture_utils::json_field_number y2 [_to_db $y2]]]]

    set pairs [list \
        [::coco_capture_utils::json_field_string command "draw_primitive"] \
        [::coco_capture_utils::json_field_string kind $kind] \
        [::coco_capture_utils::json_field_string mode [expr {$apply ? "apply" : "dry_run"}]] \
        [::coco_capture_utils::json_field_bool applied $apply] \
        [::coco_capture_utils::json_field_string page $page_name] \
        [::coco_capture_utils::json_field_json page_size_mm \
            [::coco_capture_utils::json_object_from_pairs [list \
                [::coco_capture_utils::json_field_number width $page_w] \
                [::coco_capture_utils::json_field_number height $page_h]]]] \
        [::coco_capture_utils::json_field_json coords_mm $coords] \
        [::coco_capture_utils::json_field_json expected_db_units $expected_db]]
    if {$style ne ""} { lappend pairs [::coco_capture_utils::json_field_number line_style $style] }
    if {$width ne ""} { lappend pairs [::coco_capture_utils::json_field_number line_width $width] }
    if {$kind eq "text"} { lappend pairs [::coco_capture_utils::json_field_string text $text] }

    if {$apply} {
        set before [_collect $page $kind $status]
        set before_ids [_ids $before $status]
        if {[catch {_place $kind $x1 $y1 $x2 $y2 $style $width $text} err]} {
            _fail "place_failed"                 "placing $kind failed (the object may already be on the page): $err"                 [list kind $kind]
        }
        set after [_collect $page $kind $status]
        set created [expr {[llength $after] - [llength $before]}]
        lappend pairs [::coco_capture_utils::json_field_number created_count $created]
        # Only report the new wires when every existing wire had an id to
        # tell old from new; otherwise created_count alone is the signal.
        if {$kind eq "wire" && [dict size $before_ids] == [llength $before]} {
            set wires {}
            foreach obj $after {
                set oid [::coco_capture_utils::id $obj $status]
                if {$oid ne "" && [dict exists $before_ids $oid]} { continue }
                lappend wires [_wire_json $obj $status]
            }
            lappend pairs [::coco_capture_utils::json_field_json created_wires \
                [::coco_capture_utils::json_array_from_values $wires]]
        }
        catch {$page MarkModified}
    }
    return [::coco_capture_utils::json_success \
        [::coco_capture_utils::json_object_from_pairs $pairs]]
}

# Impl entry: arg = kind|mode|x1|y1|x2|y2|line_style|line_width|text
#   kind:  wire | rect | line | text
#   mode:  dry_run (default) | apply
#   x/y:   millimetres on the active (metric) page; for rect/text, two corners
#   line_style / line_width: optional Capture enums, rect/line only
#   text:  required for kind=text; everything after the 8th '|' is the text
proc ::coco_capture_draw_primitive_impl {arg} {
    set parts [split $arg "|"]
    if {[llength $parts] < 6} {
        ::draw_primitive::_fail "invalid_arg" \
            "expected kind|mode|x1|y1|x2|y2|line_style|line_width|text" [list arg $arg]
    }
    lassign $parts kind mode x1 y1 x2 y2 style width
    set text [join [lrange $parts 8 end] "|"]
    set kind [string trim $kind]
    set mode [string trim $mode]
    if {$mode ne "apply"} { set mode "dry_run" }
    return [::draw_primitive::draw $kind $mode \
        [string trim $x1] [string trim $y1] [string trim $x2] [string trim $y2] \
        [string trim $style] [string trim $width] $text]
}
