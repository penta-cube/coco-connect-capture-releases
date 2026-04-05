# ==============================
# Overlapping Text Auto Arrange
# ==============================

# 단일 페이지 처리 헬퍼 함수
proc ::coco_auto_arrange_text_single_page {page} {
    set status [::coco_capture_utils::status]
    set text_objects [list]
    set overlap_count 0

    set null_obj "NULL"

    # PORT 객체 내부 텍스트 수집
    set pPortsIter [$page NewPortsIter $status]
    while {1} {
        if {[catch {set pPort [$pPortsIter NextPort $status]}]} { break }
        if {$pPort eq $null_obj || [::coco_capture_utils::is_null $pPort]} { break }
        
        if {![catch {set dpIter [$pPort NewDisplayPropsIter $status]}]} {
            while {1} {
                if {[catch {set dp [$dpIter NextProp $status]}]} { break }
                if {$dp eq $null_obj || [::coco_capture_utils::is_null $dp]} { break }
                lappend text_objects [dict create type "displayprop" obj $dp parent $pPort]
            }
            ::coco_capture_utils::safe_delete delete_DboDisplayPropsIter $dpIter
        }
    }
    ::coco_capture_utils::safe_delete delete_DboPagePortsIter $pPortsIter

    # GLOBAL 객체 내부 텍스트 수집
    set pGlobalsIter [$page NewGlobalsIter $status]
    while {1} {
        if {[catch {set pGlobal [$pGlobalsIter NextGlobal $status]}]} { break }
        if {$pGlobal eq $null_obj || [::coco_capture_utils::is_null $pGlobal]} { break }
        
        if {![catch {set dpIter [$pGlobal NewDisplayPropsIter $status]}]} {
            while {1} {
                if {[catch {set dp [$dpIter NextProp $status]}]} { break }
                if {$dp eq $null_obj || [::coco_capture_utils::is_null $dp]} { break }
                lappend text_objects [dict create type "displayprop" obj $dp parent $pGlobal]
            }
            ::coco_capture_utils::safe_delete delete_DboDisplayPropsIter $dpIter
        }
    }
    ::coco_capture_utils::safe_delete delete_DboPageGlobalsIter $pGlobalsIter

    # TITLE BLOCK 객체 내부 텍스트 수집
    set pTitleBlocksIter [$page NewTitleBlocksIter $status]
    while {1} {
        if {[catch {set pTitleBlock [$pTitleBlocksIter NextTitleBlock $status]}]} { break }
        if {$pTitleBlock eq $null_obj || [::coco_capture_utils::is_null $pTitleBlock]} { break }
        
        if {![catch {set dpIter [$pTitleBlock NewDisplayPropsIter $status]}]} {
            while {1} {
                if {[catch {set dp [$dpIter NextProp $status]}]} { break }
                if {$dp eq $null_obj || [::coco_capture_utils::is_null $dp]} { break }
                lappend text_objects [dict create type "displayprop" obj $dp parent $pTitleBlock]
            }
            ::coco_capture_utils::safe_delete delete_DboDisplayPropsIter $dpIter
        }
    }
    ::coco_capture_utils::safe_delete delete_DboPageTitleBlocksIter $pTitleBlocksIter

    # PART DISPLAY PROPERTIES 객체 수집
    set pPartInstsIter [$page NewPartInstsIter $status]
    while {1} {
        if {[catch {set pPartInst [$pPartInstsIter NextPartInst $status]}]} { break }
        if {$pPartInst eq $null_obj || [::coco_capture_utils::is_null $pPartInst]} { break }
        
        set pDisplayPropsIter [$pPartInst NewDisplayPropsIter $status]
        while {1} {
            if {[catch {set pDisplayProp [$pDisplayPropsIter NextProp $status]}]} { break }
            if {$pDisplayProp eq $null_obj || [::coco_capture_utils::is_null $pDisplayProp]} { break }
            lappend text_objects [dict create type "displayprop" obj $pDisplayProp parent $pPartInst]
        }
        ::coco_capture_utils::safe_delete delete_DboDisplayPropsIter $pDisplayPropsIter
    }
    ::coco_capture_utils::safe_delete delete_DboPagePartInstsIter $pPartInstsIter
    # ---- end : 모든 텍스트 객체 수집 ----

    # 수집한 모든 텍스트 객체의 Bounding Box 계산 및 절대 좌표 수집
    set bboxes [list]
    foreach item $text_objects {
        set obj [dict get $item obj]
        set type [dict get $item type]
        
        set bBox [$obj GetBoundingBox]
        set x1 [DboTclHelper_sGetCPointX [DboTclHelper_sGetCRectTopLeft $bBox]]
        set y1 [DboTclHelper_sGetCPointY [DboTclHelper_sGetCRectTopLeft $bBox]]
        set x2 [DboTclHelper_sGetCPointX [DboTclHelper_sGetCRectBottomRight $bBox]]
        set y2 [DboTclHelper_sGetCPointY [DboTclHelper_sGetCRectBottomRight $bBox]]

        if {$type eq "displayprop"} {
            # Display Properties의 경우 부모 좌표에 대해 상대적이므로 부모 보정을 수행
            set parent [dict get $item parent]
            set parentLoc [$parent GetLocation $status]
            set px [DboTclHelper_sGetCPointX $parentLoc]
            set py [DboTclHelper_sGetCPointY $parentLoc]
            
            set x1 [expr {$x1 + $px}]
            set x2 [expr {$x2 + $px}]
            set y1 [expr {$y1 + $py}]
            set y2 [expr {$y2 + $py}]
        }

        # 박스 방향 정상화
        if {$x1 > $x2} { set tmp $x1; set x1 $x2; set x2 $tmp }
        if {$y1 > $y2} { set tmp $y1; set y1 $y2; set y2 $tmp }

        dict set item x1 $x1
        dict set item y1 $y1
        dict set item x2 $x2
        dict set item y2 $y2
        
        lappend bboxes $item
    }

    # 위에서 계산한 내용들을 토대로, 겹친 텍스트들을 계산 및 이동
    set len [llength $bboxes]
    for {set i 0} {$i < [expr {$len - 1}]} {incr i} {
        set item1 [lindex $bboxes $i]
        
        for {set j [expr {$i + 1}]} {$j < $len} {incr j} {
            set item2 [lindex $bboxes $j]
            
            set rect1_x1 [dict get $item1 x1]
            set rect1_y1 [dict get $item1 y1]
            set rect1_x2 [dict get $item1 x2]
            set rect1_y2 [dict get $item1 y2]

            set rect2_x1 [dict get $item2 x1]
            set rect2_y1 [dict get $item2 y1]
            set rect2_x2 [dict get $item2 x2]
            set rect2_y2 [dict get $item2 y2]

            # 겹침 확인 (AABB Collision)
            if {!($rect1_x2 <= $rect2_x1 || $rect1_x1 >= $rect2_x2 || $rect1_y2 <= $rect2_y1 || $rect1_y1 >= $rect2_y2)} {
                incr overlap_count
                
                # 겹칠 경우 객체를 바로 아래(Y양수 방향)로 이동
                set shift_y [expr {$rect1_y2 - $rect2_y1}]
                
                set obj2 [dict get $item2 obj]
                set loc2 [$obj2 GetLocation $status]
                set nx [DboTclHelper_sGetCPointX $loc2]
                set ny [expr {[DboTclHelper_sGetCPointY $loc2] + $shift_y}]
                set newLoc [DboTclHelper_sMakeCPoint $nx $ny]
                
                $obj2 SetLocation $newLoc
                
                # Update item2's absolute box for subsequent checks
                dict set item2 y1 [expr {$rect2_y1 + $shift_y}]
                dict set item2 y2 [expr {$rect2_y2 + $shift_y}]
                lset bboxes $j $item2
            }
        }
    }

    return [dict create total_objects $len overlap_count $overlap_count move_count $overlap_count]
}

# 모든 페이지 처리 (기존 단일 페이지 명령어 통합, 옵션으로 페이지 지정 가능)
proc ::coco_auto_arrange_text_impl {{target_page_name ""}} {
    set target_page_name [string trim $target_page_name]

    if {[catch {set session [::coco_capture_utils::session]} err]} {
        error [::coco_capture_utils::json_error "session_error" "Failed to get Capture session: $err" [::coco_capture_utils::json_object_from_pairs [list \
            [::coco_capture_utils::json_field_string command "auto_arrange_text"]]]]
    }

    set status [::coco_capture_utils::status]
    if {[catch {set design [::coco_capture_utils::active_design $session $status]} err]} {
        error [::coco_capture_utils::json_error "design_error" "Failed to get active design: $err" [::coco_capture_utils::json_object_from_pairs [list \
            [::coco_capture_utils::json_field_string command "auto_arrange_text"]]]]
    }

    # 모든 스키매틱 페이지 순회
    set iter [::coco_capture_utils::schem_iter $design $status]

    set total_pages 0
    set total_objects 0
    set total_overlaps 0
    set page_results {}

    set null_obj "NULL"

    while {1} {
        if {[catch {set view [$iter NextView $status]}]} { break }
        if {$view eq $null_obj || [::coco_capture_utils::is_null $view]} { break }
        
        set schematic [::coco_capture_utils::to_schematic $view]

        if {[::coco_capture_utils::is_null $schematic]} {
            continue
        }

        # 스키매틱의 모든 페이지 순회
        set pageIter [$schematic NewPagesIter $status]
        while {1} {
            if {[catch {set page [$pageIter NextPage $status]}]} { break }
            if {$page eq $null_obj || [::coco_capture_utils::is_null $page]} { break }

            set pageName [::coco_capture_utils::name $page]
            if {$target_page_name ne "" && [string compare -nocase $pageName $target_page_name] != 0} {
                continue
            }

            set result [::coco_auto_arrange_text_single_page $page]

            incr total_pages
            incr total_objects [dict get $result total_objects]
            incr total_overlaps [dict get $result overlap_count]

            lappend page_results [::coco_capture_utils::json_object_from_pairs [list \
                [::coco_capture_utils::json_field_string page $pageName] \
                [::coco_capture_utils::json_field_number objects [dict get $result total_objects]] \
                [::coco_capture_utils::json_field_number overlaps [dict get $result overlap_count]]]]
        }
        ::coco_capture_utils::safe_delete delete_DboPageIter $pageIter
    }
    ::coco_capture_utils::safe_delete delete_DboViewIter $iter

    if {$target_page_name ne "" && $total_pages == 0} {
        error [::coco_capture_utils::json_error "page_not_found" "Page '$target_page_name' was not found in the active design" [::coco_capture_utils::json_object_from_pairs [list \
            [::coco_capture_utils::json_field_string command "auto_arrange_text"]]]]
    }

    return [::coco_capture_utils::json_success [::coco_capture_utils::json_object_from_pairs [list \
        [::coco_capture_utils::json_field_string command "auto_arrange_text"] \
        [::coco_capture_utils::json_field_string message "Overlap detection completed for all pages"] \
        [::coco_capture_utils::json_field_number total_pages $total_pages] \
        [::coco_capture_utils::json_field_number total_objects $total_objects] \
        [::coco_capture_utils::json_field_number total_overlaps $total_overlaps] \
        [::coco_capture_utils::json_field_json pages [::coco_capture_utils::json_array_from_values $page_results]]]]]
}