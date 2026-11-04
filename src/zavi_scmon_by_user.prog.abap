*&---------------------------------------------------------------------*
*& Report ZAVI_SCMON_BY_USER                       (package $AVI)
*&---------------------------------------------------------------------*
*& Approximate SCMON usage per user.
*&  1. Read the user's workload statistics (STAD) via SWNC_STATREC_READ
*&  2. Collect distinct entry points (TCODE / REPORT / ENTRY_ID)
*&  3. Match them against SCMON request entry points (SCMON_VDATA-ROOTNAME)
*&     and list the monitored programs/procedures with SCMON counts.
*&
*& !! APPROXIMATION !! SCMON aggregates counts across ALL users. Counters
*&    shown are system-wide for that entry point, not the user's own calls.
*&    Rows only mean "this user started an entry point which SCMON saw
*&    reaching this procedure".
*&---------------------------------------------------------------------*
REPORT zavi_scmon_by_user.


PARAMETERS: p_user  TYPE syuname   DEFAULT sy-uname OBLIGATORY,
            p_datef TYPE sydatum   DEFAULT sy-datum OBLIGATORY,
            p_timef TYPE syuzeit   DEFAULT '000000',
            p_datet TYPE sydatum   DEFAULT sy-datum OBLIGATORY,
            p_timet TYPE syuzeit   DEFAULT '235959',
            p_slice AS CHECKBOX    DEFAULT abap_true. "restrict SCMON slices to date range

CLASS lcl_app DEFINITION FINAL.
  PUBLIC SECTION.
    TYPES: BEGIN OF ty_entry,
             rootname TYPE scmon_rootname,
             source   TYPE char10,          "TCODE / REPORT / ENTRY_ID
             steps    TYPE i,               "user's dialog steps (STAD)
           END OF ty_entry,
           tt_entry TYPE SORTED TABLE OF ty_entry WITH UNIQUE KEY rootname.

    TYPES: BEGIN OF ty_out,
             uname      TYPE syuname,
             roottype   TYPE scmon_roottype,
             rootname   TYPE scmon_rootname,
             user_steps TYPE i,
             object     TYPE trobjtype,
             obj_name   TYPE sobj_name,
             progname   TYPE progname,
             proctype   TYPE scmon_vdata-proctype,
             classname  TYPE scmon_vdata-classname,
             procname   TYPE scmon_vdata-procname,
             counter    TYPE int8,                  "SYSTEM-WIDE count (SUM of SCMON_EXECNT)
           END OF ty_out,
           tt_out TYPE STANDARD TABLE OF ty_out WITH EMPTY KEY.

    METHODS run.

  PRIVATE SECTION.
    DATA mt_entry TYPE tt_entry.
    DATA mt_out   TYPE tt_out.

    METHODS read_stad.
    METHODS add_entry IMPORTING iv_name   TYPE csequence
                                iv_source TYPE char10.
    METHODS read_scmon.
    METHODS display.
ENDCLASS.

CLASS lcl_app IMPLEMENTATION.

  METHOD run.
    read_stad( ).
    IF mt_entry IS INITIAL.
      MESSAGE |No statistics records for { p_user } in the selected interval| TYPE 'S' DISPLAY LIKE 'W'.
      RETURN.
    ENDIF.
    read_scmon( ).
    display( ).
  ENDMETHOD.

  METHOD read_stad.
    DATA lt_main TYPE swnc_t_mainrec.
    DATA lv_tz   TYPE swnctimezone.

    "SWNC_STATREC_READ defaults to UTC - use system time zone like
    "SAPWL_STATREC_DIRECT_READ does internally
    CALL FUNCTION 'GET_SYSTEM_TIMEZONE'
      IMPORTING  timezone = lv_tz
      EXCEPTIONS OTHERS   = 1.
    IF sy-subrc <> 0.
      lv_tz = 'UTC'.
    ENDIF.

    CALL FUNCTION 'SWNC_STATREC_READ'
      EXPORTING
        read_timezone   = lv_tz
        read_start_date = p_datef
        read_start_time = p_timef
        read_end_date   = p_datet
        read_end_time   = p_timet
        read_username   = p_user
      IMPORTING
        normal_records  = lt_main
      EXCEPTIONS
        read_error      = 1
        OTHERS          = 2.
    IF sy-subrc <> 0.
      MESSAGE 'Error reading workload statistics (SWNC_STATREC_READ)' TYPE 'E'.
    ENDIF.

    LOOP AT lt_main ASSIGNING FIELD-SYMBOL(<m>) WHERE account = p_user.
      add_entry( iv_name = <m>-tcode    iv_source = 'TCODE' ).
      add_entry( iv_name = <m>-report   iv_source = 'REPORT' ).
      "ENTRY_ID: RFC function / HTTP / batch entry, e.g. 'RFC_READ_TABLE ...'
      add_entry( iv_name = <m>-entry_id iv_source = 'ENTRY_ID' ).
    ENDLOOP.
  ENDMETHOD.

  METHOD add_entry.
    DATA(lv_name) = CONV scmon_rootname( to_upper( condense( iv_name ) ) ).
    IF lv_name IS INITIAL.
      RETURN.
    ENDIF.
    "ENTRY_ID may carry trailing qualifiers separated by blanks - keep 1st token
    SPLIT lv_name AT space INTO lv_name DATA(lv_rest) ##NEEDED.

    READ TABLE mt_entry ASSIGNING FIELD-SYMBOL(<e>) WITH TABLE KEY rootname = lv_name.
    IF sy-subrc = 0.
      <e>-steps += 1.
    ELSE.
      INSERT VALUE #( rootname = lv_name source = iv_source steps = 1 ) INTO TABLE mt_entry.
    ENDIF.
  ENDMETHOD.

  METHOD read_scmon.
    DATA lt_names TYPE RANGE OF scmon_rootname.
    lt_names = VALUE #( FOR e IN mt_entry ( sign = 'I' option = 'EQ' low = e-rootname ) ).

    "SCMON_SLICE-STARTDATE/ENDDATE are DATS (slices are day/week granular)
    "Matched on ROOTNAME only (ROOTTYPE shown for info) - avoids hard-coding
    "SCMON_ROOTTYPE fixed values. Aggregate counter over slices.
    SELECT roottype, rootname, object, obj_name, progname,
           proctype, classname, procname,
           SUM( counter ) AS counter
      FROM scmon_vdata
      WHERE rootname IN @lt_names
        AND ( @p_slice = @abap_false
              OR ( sliceend >= @p_datef AND slicestart <= @p_datet ) )
      GROUP BY roottype, rootname, object, obj_name, progname,
               proctype, classname, procname
      INTO CORRESPONDING FIELDS OF TABLE @mt_out.

    LOOP AT mt_out ASSIGNING FIELD-SYMBOL(<o>).
      <o>-uname      = p_user.
      <o>-user_steps = VALUE #( mt_entry[ rootname = <o>-rootname ]-steps OPTIONAL ).
    ENDLOOP.
    SORT mt_out BY rootname progname procname.
  ENDMETHOD.

  METHOD display.
    TRY.
        cl_salv_table=>factory( IMPORTING r_salv_table = DATA(lo_alv)
                                CHANGING  t_table      = mt_out ).
        lo_alv->get_functions( )->set_all( ).
        lo_alv->get_columns( )->set_optimize( ).

        DATA(lo_cols) = lo_alv->get_columns( ).
        CAST cl_salv_column_table( lo_cols->get_column( 'USER_STEPS' ) )->set_long_text( 'User steps (STAD)' ).
        CAST cl_salv_column_table( lo_cols->get_column( 'COUNTER' ) )->set_long_text( 'SCMON calls (ALL users)' ).

        lo_alv->get_display_settings( )->set_list_header(
          |SCMON objects reached from entry points used by { p_user } - APPROXIMATE, counts are system-wide| ).
        lo_alv->get_aggregations( )->add_aggregation( 'COUNTER' ).
        lo_alv->display( ).
      CATCH cx_salv_msg cx_salv_not_found cx_salv_data_error cx_salv_existing INTO DATA(lx).
        MESSAGE lx TYPE 'E'.
    ENDTRY.
  ENDMETHOD.

ENDCLASS.

AT SELECTION-SCREEN.
  IF p_datet < p_datef OR ( p_datet = p_datef AND p_timet < p_timef ).
    MESSAGE 'End must be after start' TYPE 'E'.
  ENDIF.

START-OF-SELECTION.
  NEW lcl_app( )->run( ).
