# net.tcl - Net manipulation utilities for OrCAD Capture

proc ::coco_capture_rename_net_impl {old_name new_name} {

    set old_name [string trim $old_name]
    set new_name [string trim $new_name]

    if {$old_name eq "" || $new_name eq ""} {
        error "Invalid argument"
    }

    # session / design
    set session [::coco_capture_utils::session]
    set status  [::coco_capture_utils::status]
    set design  [::coco_capture_utils::active_design $session $status]

    if {![::coco_capture_utils::status_ok $status]} {
        error "Failed to get active design"
    }

    set null_obj "NULL"
    set updated 0

    # schematic iterator
    set schem_iter [::coco_capture_utils::schem_iter $design $status]

    while {1} {
        set view [$schem_iter NextView $status]
        if {$view eq $null_obj || [::coco_capture_utils::is_null $view]} break

        set schematic [::coco_capture_utils::to_schematic $view]
        set pages_iter [$schematic NewPagesIter $status]

        while {1} {
            set page [$pages_iter NextPage $status]
            if {$page eq $null_obj || [::coco_capture_utils::is_null $page]} break

            # =========================
            # 1. PORT 처리
            # =========================
            if {![catch {set ports_iter [$page NewPortsIter $status]}]} {

                while {1} {
                    set port [$ports_iter NextPort $status]
                    if {$port eq $null_obj || [::coco_capture_utils::is_null $port]} break

                    set name_cstr [DboTclHelper_sMakeCString]
                    if {[catch {$port GetName $name_cstr}]} continue

                    set pname [DboTclHelper_sGetConstCharPtr $name_cstr]

                    if {$pname eq $old_name} {
                        set new_cstr [DboTclHelper_sMakeCString $new_name]

                        if {![catch {$port SetName $new_cstr}]} {
                            incr updated

                            # Port 변경 후 연결된 Net 업데이트
                            if {![catch {set net [$port GetNet $status]} err] && ![::coco_capture_utils::is_null $net]} {
                                catch {$net UpdateNetName $status}
                            }
                        }
                    }
                }

                ::coco_capture_utils::safe_delete delete_DboPortsIter $ports_iter
            }

            # =========================
            # 2. GLOBAL 처리
            # =========================
            if {![catch {set globals_iter [$page NewGlobalsIter $status]}]} {

                while {1} {
                    set global [$globals_iter NextGlobal $status]
                    if {$global eq $null_obj || [::coco_capture_utils::is_null $global]} break

                    set name_cstr [DboTclHelper_sMakeCString]
                    if {[catch {$global GetName $name_cstr}]} continue

                    set gname [DboTclHelper_sGetConstCharPtr $name_cstr]

                    if {$gname eq $old_name} {
                        set new_cstr [DboTclHelper_sMakeCString $new_name]

                        if {![catch {$global SetName $new_cstr}]} {
                            incr updated
                        }
                    }
                }

                ::coco_capture_utils::safe_delete delete_DboGlobalsIter $globals_iter
            }

            # =========================
            # 3. Alias (DisplayProp) 처리
            # =========================
            if {![catch {set wires_iter [$page NewWiresIter $status]}]} {

                while {1} {
                    set wire [$wires_iter NextWire $status]
                    if {$wire eq $null_obj || [::coco_capture_utils::is_null $wire]} break

                    if {[catch {set props_iter [$wire NewDisplayPropsIter $status]}]} continue

                    while {1} {
                        set dprop [$props_iter NextProp $status]
                        if {$dprop eq $null_obj || [::coco_capture_utils::is_null $dprop]} break

                        # 값 가져오기
                        set val_cstr [DboTclHelper_sMakeCString]
                        if {[catch {$dprop GetValue $val_cstr}]} continue

                        set val [DboTclHelper_sGetConstCharPtr $val_cstr]

                        if {$val eq $old_name} {
                            set new_cstr [DboTclHelper_sMakeCString $new_name]

                            if {![catch {$dprop SetValue $new_cstr}]} {
                                incr updated
                            }
                        }
                    }

                    ::coco_capture_utils::safe_delete delete_DboDisplayPropsIter $props_iter
                }

                ::coco_capture_utils::safe_delete delete_DboWireIter $wires_iter
            }
        }

        ::coco_capture_utils::safe_delete delete_DboPageIter $pages_iter
    }

    ::coco_capture_utils::safe_delete delete_DboViewIter $schem_iter

    if {$updated == 0} {
        return [::coco_capture_utils::json_error "No matching Port / Global / Alias found for net: $old_name"]
    }

    catch {$design UpdateConnectivity $status}
    catch {$design Check $status}
    catch {update idletasks}
    catch {update}
    catch {ZoomRedraw}

    return [::coco_capture_utils::json_success \
        [::coco_capture_utils::json_object_from_pairs [list \
            [::coco_capture_utils::json_field_string command "rename_net"] \
            [::coco_capture_utils::json_field_string old_name $old_name] \
            [::coco_capture_utils::json_field_string new_name $new_name] \
            [::coco_capture_utils::json_field_string status "renamed"]]]]
}
