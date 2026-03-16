namespace eval ::coco_capture_utils {}

proc ::coco_capture_utils::cmd_exists {name} {
    expr {[llength [info commands $name]] > 0}
}

proc ::coco_capture_utils::is_null {obj} {
    expr {$obj eq "" || [string equal -nocase $obj "NULL"]}
}

proc ::coco_capture_utils::status {} {
    if {[cmd_exists DboState]} {
        return [DboState]
    }
    return ""
}

proc ::coco_capture_utils::safe_delete {delete_proc iter_obj} {
    if {$iter_obj eq "" || [is_null $iter_obj]} {
        return
    }
    if {[cmd_exists $delete_proc]} {
        catch {$delete_proc $iter_obj}
    }
}

proc ::coco_capture_utils::cstring_get {obj method} {
    if {![cmd_exists DboTclHelper_sMakeCString] || ![cmd_exists DboTclHelper_sGetConstCharPtr]} {
        return ""
    }
    if {[catch {set cstr [DboTclHelper_sMakeCString]}]} {
        return ""
    }
    if {[catch {$obj $method $cstr}]} {
        return ""
    }
    return [string trim [DboTclHelper_sGetConstCharPtr $cstr]]
}

proc ::coco_capture_utils::name {obj} {
    set v [cstring_get $obj GetName]
    if {$v ne ""} {
        return $v
    }
    set v [cstring_get $obj GetNetName]
    if {$v ne ""} {
        return $v
    }
    if {[catch {set v [$obj GetName]}]} {
        return ""
    }
    return [string trim $v]
}

proc ::coco_capture_utils::refdes {placed_inst} {
    set v [cstring_get $placed_inst GetReferenceDesignator]
    if {$v ne ""} {
        return $v
    }
    return [name $placed_inst]
}

proc ::coco_capture_utils::id {obj {status ""}} {
    if {$obj eq "" || [is_null $obj]} {
        return ""
    }
    if {$status ne "" && ![catch {set oid [$obj GetId $status]}]} {
        return $oid
    }
    if {![catch {set oid [$obj GetId]}]} {
        return $oid
    }
    return ""
}

proc ::coco_capture_utils::page_path {schematic_name page_name} {
    if {$schematic_name eq "" && $page_name eq ""} {
        return ""
    }
    if {$schematic_name eq ""} {
        return $page_name
    }
    if {$page_name eq ""} {
        return $schematic_name
    }
    return "${schematic_name}/${page_name}"
}

proc ::coco_capture_utils::session {} {
    if {[info exists ::DboSession_s_pDboSession] && ![is_null $::DboSession_s_pDboSession]} {
        set session $::DboSession_s_pDboSession
        catch {DboSession -this $session}
        return $session
    }
    if {[cmd_exists GetActivePMDesign]} {
        return "__CAPTURE_SESSION_IMPLICIT__"
    }
    error "Capture session handle is not available"
}

proc ::coco_capture_utils::active_design {session status} {
    if {[cmd_exists GetActivePMDesign]} {
        if {![catch {set design [GetActivePMDesign]}] && ![is_null $design]} {
            return $design
        }
    }
    if {$session ne "" && ![is_null $session]} {
        if {$status ne "" && ![catch {set design [$session GetActiveDesign $status]}] && ![is_null $design]} {
            return $design
        }
        if {![catch {set design [$session GetActiveDesign]}] && ![is_null $design]} {
            return $design
        }
    }
    error "active design not available"
}

proc ::coco_capture_utils::schem_iter {design status} {
    if {[info exists ::IterDefs_SCHEMATICS]} {
        if {![catch {set iter [$design NewViewsIter $status $::IterDefs_SCHEMATICS]}]} {
            return $iter
        }
    }
    if {![catch {set iter [$design NewViewsIter $status]}]} {
        return $iter
    }
    error "cannot create schematic views iterator"
}

proc ::coco_capture_utils::to_schematic {view_obj} {
    if {[cmd_exists DboViewToDboSchematic]} {
        if {![catch {set schematic [DboViewToDboSchematic $view_obj]}] && ![is_null $schematic]} {
            return $schematic
        }
    }
    return $view_obj
}

proc ::coco_capture_utils::status_ok {status_obj} {
    if {$status_obj eq ""} {
        return 0
    }
    if {[catch {set ok [$status_obj OK]}]} {
        return 0
    }
    return [expr {$ok ? 1 : 0}]
}

proc ::coco_capture_utils::json_escape {text} {
    set escaped [string map [list "\\" "\\\\" "\"" "\\\"" "\b" "\\b" "\f" "\\f" "\n" "\\n" "\r" "\\r" "\t" "\\t"] $text]
    set out ""
    foreach ch [split $escaped ""] {
        if {$ch eq ""} {
            continue
        }
        scan $ch %c code
        if {$code < 32} {
            append out [format "\\u%04x" $code]
        } else {
            append out $ch
        }
    }
    return $out
}

proc ::coco_capture_utils::json_quote {text} {
    return "\"[json_escape $text]\""
}

proc ::coco_capture_utils::json_bool {value} {
    expr {$value ? "true" : "false"}
}

proc ::coco_capture_utils::json_number {value} {
    return $value
}

proc ::coco_capture_utils::json_null {} {
    return "null"
}

proc ::coco_capture_utils::json_field_string {key value} {
    return "[json_quote $key]:[json_quote $value]"
}

proc ::coco_capture_utils::json_field_number {key value} {
    return "[json_quote $key]:[json_number $value]"
}

proc ::coco_capture_utils::json_field_bool {key value} {
    return "[json_quote $key]:[json_bool $value]"
}

proc ::coco_capture_utils::json_field_json {key json_value} {
    return "[json_quote $key]:$json_value"
}

proc ::coco_capture_utils::json_object_from_pairs {pairs} {
    return "\{[join $pairs ,]\}"
}

proc ::coco_capture_utils::json_array_from_values {values} {
    return "\[[join $values ,]\]"
}

proc ::coco_capture_utils::json_from_string_dict {dict_value} {
    set pairs {}
    dict for {key value} $dict_value {
        lappend pairs [json_field_string $key $value]
    }
    return [json_object_from_pairs $pairs]
}

proc ::coco_capture_utils::json_success {data_json} {
    return [json_object_from_pairs [list \
        [json_field_bool ok 1] \
        [json_field_json data $data_json]]]
}

proc ::coco_capture_utils::json_error {code message {details_json ""}} {
    if {$details_json eq ""} {
        set details_json [json_null]
    }
    set error_json [json_object_from_pairs [list \
        [json_field_string code $code] \
        [json_field_string message $message] \
        [json_field_json details $details_json]]]
    return [json_object_from_pairs [list \
        [json_field_bool ok 0] \
        [json_field_json error $error_json]]]
}

proc ::coco_capture_utils::looks_like_json {text} {
    set trimmed [string trim $text]
    expr {[string length $trimmed] >= 2 && [string index $trimmed 0] eq "\{" && [string index $trimmed end] eq "\}"} 
}

proc ::coco_capture_utils::ensure_error_json {message {code "bridge_error"}} {
    if {[looks_like_json $message]} {
        return $message
    }
    return [json_error $code $message]
}
