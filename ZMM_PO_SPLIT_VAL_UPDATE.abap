*---------------------------------------------------------------------*
* Report ZMM_PO_SPLIT_VAL_UPDATE
* Mass update of the valuation type (BWTAR) on open purchase order
* items, mainly for background jobs.
* Valuation type from table ZPTP_PO_VALTYPE (same rules as BAdI class
* ZCL_IM_MM_PO_SPLIT_VAL):
*   1. plant + material type (MARA-MTART) + year
*   2. plant + blank material type + year (plant default)
* Year = fiscal year of the key date in the item's company code. Key
* date = run date of the program (P_RUN, SY-DATLO) or P_DATE (P_KEY).
* Open item = standard PO (BSTYP F), item and PO not deleted, not
* delivery completed, no PO history (EKBE) and no inbound delivery
* (EKES-VBELN). Only split-valuated materials; the new valuation type
* must have its own valuation record (MBEW, not flagged for deletion).
* Update with BAPI_PO_CHANGE, one call per PO, without output
* determination (NO_MESSAGING). Test run = BAPI_PO_CHANGE with TESTRUN.
* Messages: class ZPTP_SPLIT_VAL, 023, 024 and 100 - 105.
*---------------------------------------------------------------------*
REPORT zmm_po_split_val_update MESSAGE-ID zptp_split_val.

TABLES ekpo.

SELECT-OPTIONS: s_werks FOR ekpo-werks,
                s_ebeln FOR ekpo-ebeln,
                s_matnr FOR ekpo-matnr.

" Key date of the fiscal year: run date of the program or P_DATE
PARAMETERS: p_run  RADIOBUTTON GROUP date DEFAULT 'X' USER-COMMAND date,
            p_key  RADIOBUTTON GROUP date,
            p_date TYPE sy-datum MODIF ID key.

PARAMETERS p_test AS CHECKBOX DEFAULT abap_true.


CLASS lcl_app DEFINITION FINAL.

  PUBLIC SECTION.
    METHODS run.

  PRIVATE SECTION.

    TYPES:
      BEGIN OF ty_item,
        ebeln TYPE ebeln,
        ebelp TYPE ebelp,
        bukrs TYPE bukrs,
        werks TYPE werks_d,
        matnr TYPE matnr,
        bwtar TYPE bwtar_d,
        mtart TYPE mtart,
        bwkey TYPE bwkey,
      END OF ty_item,
      tt_item TYPE STANDARD TABLE OF ty_item WITH EMPTY KEY,

      BEGIN OF ty_log,
        msgty     TYPE bapi_mtype,
        ebeln     TYPE ebeln,
        ebelp     TYPE ebelp,
        werks     TYPE werks_d,
        matnr     TYPE matnr,
        mtart     TYPE mtart,
        gjahr     TYPE gjahr,
        bwtar_old TYPE bwtar_d,
        bwtar_new TYPE bwtar_d,
        message   TYPE bapi_msg,
      END OF ty_log,
      tt_log TYPE STANDARD TABLE OF ty_log WITH EMPTY KEY,

      BEGIN OF ty_year_buffer,
        bukrs TYPE bukrs,
        gjahr TYPE gjahr,
      END OF ty_year_buffer,
      tt_year_buffer TYPE HASHED TABLE OF ty_year_buffer
                     WITH UNIQUE KEY bukrs,

      BEGIN OF ty_valtype_buffer,
        werks TYPE werks_d,
        mtart TYPE mtart,
        gjahr TYPE gjahr,
        bwtar TYPE bwtar_d,
      END OF ty_valtype_buffer,
      tt_valtype_buffer TYPE HASHED TABLE OF ty_valtype_buffer
                        WITH UNIQUE KEY werks mtart gjahr,

      BEGIN OF ty_mbew_buffer,
        matnr  TYPE matnr,
        bwkey  TYPE bwkey,
        bwtar  TYPE bwtar_d,
        exists TYPE abap_bool,
      END OF ty_mbew_buffer,
      tt_mbew_buffer TYPE HASHED TABLE OF ty_mbew_buffer
                     WITH UNIQUE KEY matnr bwkey bwtar.

    "! Key date (run date or P_DATE) - base of the fiscal year
    DATA mv_date TYPE d.

    DATA mt_log            TYPE tt_log.
    DATA mt_year_buffer    TYPE tt_year_buffer.
    DATA mt_valtype_buffer TYPE tt_valtype_buffer.
    DATA mt_mbew_buffer    TYPE tt_mbew_buffer.

    DATA mv_selected  TYPE i.
    DATA mv_changed   TYPE i.
    DATA mv_unchanged TYPE i.
    DATA mv_errors    TYPE i.

    METHODS select_items
      RETURNING VALUE(rt_item) TYPE tt_item.

    "! Log line with the new valuation type, or MSGTY = E on error
    METHODS determine
      IMPORTING is_item       TYPE ty_item
      RETURNING VALUE(rs_log) TYPE ty_log.

    "! One BAPI_PO_CHANGE call for all items of the PO to change
    METHODS change_po
      IMPORTING iv_ebeln  TYPE ebeln
      CHANGING  ct_change TYPE tt_log.

    "! Fiscal year of the run date; initial if it cannot be determined
    METHODS get_fiscal_year
      IMPORTING iv_bukrs        TYPE bukrs
      RETURNING VALUE(rv_gjahr) TYPE gjahr.

    "! Material type entry first, plant default (blank MTART) second
    METHODS get_valtype_from_table
      IMPORTING iv_werks        TYPE werks_d
                iv_mtart        TYPE mtart
                iv_gjahr        TYPE gjahr
      RETURNING VALUE(rv_bwtar) TYPE bwtar_d.

    METHODS read_valtype
      IMPORTING iv_werks        TYPE werks_d
                iv_mtart        TYPE mtart
                iv_gjahr        TYPE gjahr
      RETURNING VALUE(rv_bwtar) TYPE bwtar_d.

    METHODS valtype_exists
      IMPORTING iv_matnr         TYPE matnr
                iv_bwkey         TYPE bwkey
                iv_bwtar         TYPE bwtar_d
      RETURNING VALUE(rv_exists) TYPE abap_bool.

    METHODS display_log.

    METHODS set_column_text
      IMPORTING io_columns TYPE REF TO cl_salv_columns_table
                iv_name    TYPE lvc_fname
                iv_short   TYPE scrtext_s
                iv_medium  TYPE scrtext_m
      RAISING   cx_salv_not_found.

ENDCLASS.


CLASS lcl_app IMPLEMENTATION.

  METHOD run.

    DATA lt_change TYPE tt_log.

    mv_date = COND #( WHEN p_key = abap_true THEN p_date
                      ELSE sy-datlo ).

    DATA(lt_item) = select_items( ).
    mv_selected = lines( lt_item ).

    IF lt_item IS INITIAL.
      MESSAGE s104.
      RETURN.
    ENDIF.

    LOOP AT lt_item ASSIGNING FIELD-SYMBOL(<ls_item>)
         GROUP BY <ls_item>-ebeln INTO DATA(lv_ebeln).

      CLEAR lt_change.

      LOOP AT GROUP lv_ebeln ASSIGNING FIELD-SYMBOL(<ls_member>).
        DATA(ls_log) = determine( <ls_member> ).
        IF ls_log-msgty = 'E'.
          mv_errors = mv_errors + 1.
          APPEND ls_log TO mt_log.
        ELSEIF ls_log-bwtar_new = ls_log-bwtar_old.
          mv_unchanged = mv_unchanged + 1.   " nothing to do, not logged
        ELSE.
          APPEND ls_log TO lt_change.
        ENDIF.
      ENDLOOP.

      IF lt_change IS NOT INITIAL.
        change_po( EXPORTING iv_ebeln  = lv_ebeln
                   CHANGING  ct_change = lt_change ).
        APPEND LINES OF lt_change TO mt_log.
      ENDIF.

    ENDLOOP.

    " Summary - goes to the job log in background
    MESSAGE s103 WITH mv_selected mv_changed mv_unchanged mv_errors.

    display_log( ).

  ENDMETHOD.


  METHOD select_items.

    " Split-valuated materials only: header valuation record (BWTAR =
    " space) with a valuation category.
    " No PO history at all (as the BAdI) and no inbound delivery.
    SELECT p~ebeln, p~ebelp, p~bukrs, p~werks, p~matnr, p~bwtar,
           m~mtart, w~bwkey
      FROM ekko AS k
      INNER JOIN ekpo  AS p ON p~ebeln = k~ebeln
      INNER JOIN mara  AS m ON m~matnr = p~matnr
      INNER JOIN t001w AS w ON w~werks = p~werks
      INNER JOIN mbew  AS v ON  v~matnr = p~matnr
                            AND v~bwkey = w~bwkey
                            AND v~bwtar = @space
      WHERE k~bstyp = 'F'
        AND k~loekz = @space
        AND p~ebeln IN @s_ebeln
        AND p~werks IN @s_werks
        AND p~matnr IN @s_matnr
        AND p~loekz = @space
        AND p~elikz = @space
        AND v~bwtty <> @space
        AND NOT EXISTS ( SELECT ebeln FROM ekbe
                           WHERE ebeln = p~ebeln
                             AND ebelp = p~ebelp )
        AND NOT EXISTS ( SELECT ebeln FROM ekes
                           WHERE ebeln = p~ebeln
                             AND ebelp = p~ebelp
                             AND vbeln <> @space )
      ORDER BY p~ebeln, p~ebelp
      INTO CORRESPONDING FIELDS OF TABLE @rt_item.

  ENDMETHOD.


  METHOD determine.

    rs_log = VALUE #( ebeln     = is_item-ebeln
                      ebelp     = is_item-ebelp
                      werks     = is_item-werks
                      matnr     = is_item-matnr
                      mtart     = is_item-mtart
                      bwtar_old = is_item-bwtar ).

    rs_log-gjahr = get_fiscal_year( is_item-bukrs ).
    IF rs_log-gjahr IS INITIAL.
      rs_log-msgty = 'E'.
      MESSAGE e100 WITH is_item-bukrs mv_date INTO rs_log-message.
      RETURN.
    ENDIF.

    rs_log-bwtar_new = get_valtype_from_table( iv_werks = is_item-werks
                                               iv_mtart = is_item-mtart
                                               iv_gjahr = rs_log-gjahr ).
    IF rs_log-bwtar_new IS INITIAL.
      rs_log-msgty = 'E'.
      MESSAGE e024 WITH is_item-werks is_item-mtart rs_log-gjahr
              INTO rs_log-message.
      RETURN.
    ENDIF.

    IF rs_log-bwtar_new = rs_log-bwtar_old.
      RETURN.
    ENDIF.

    " Valuation record must exist, otherwise GR will fail
    IF valtype_exists( iv_matnr = is_item-matnr
                       iv_bwkey = is_item-bwkey
                       iv_bwtar = rs_log-bwtar_new ) = abap_false.
      rs_log-msgty = 'E'.
      MESSAGE e023 WITH rs_log-bwtar_new |{ is_item-matnr ALPHA = OUT }|
                        is_item-werks
              INTO rs_log-message.
    ENDIF.

  ENDMETHOD.


  METHOD change_po.

    DATA lt_poitem  TYPE STANDARD TABLE OF bapimepoitem.
    DATA lt_poitemx TYPE STANDARD TABLE OF bapimepoitemx.
    DATA lt_return  TYPE STANDARD TABLE OF bapiret2.

    lt_poitem  = VALUE #( FOR ls_c IN ct_change
                          ( po_item  = ls_c-ebelp
                            val_type = ls_c-bwtar_new ) ).
    lt_poitemx = VALUE #( FOR ls_c IN ct_change
                          ( po_item  = ls_c-ebelp
                            po_itemx = abap_true
                            val_type = abap_true ) ).

    " The BAdI keeps a filled BWTAR on saved items (override setting
    " off), so the value passed here is not replaced
    CALL FUNCTION 'BAPI_PO_CHANGE'
      EXPORTING
        purchaseorder = iv_ebeln
        testrun       = p_test
        no_messaging  = abap_true
      TABLES
        return        = lt_return
        poitem        = lt_poitem
        poitemx       = lt_poitemx.

    " The BAPI changes all items of the PO or none
    LOOP AT lt_return INTO DATA(ls_return)
         WHERE type = 'E' OR type = 'A'.
      EXIT.
    ENDLOOP.

    IF sy-subrc = 0.
      CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
      LOOP AT ct_change ASSIGNING FIELD-SYMBOL(<ls_change>).
        <ls_change>-msgty   = 'E'.
        <ls_change>-message = ls_return-message.
      ENDLOOP.
      mv_errors = mv_errors + lines( ct_change ).
      RETURN.
    ENDIF.

    IF p_test = abap_true.
      CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
    ELSE.
      CALL FUNCTION 'BAPI_TRANSACTION_COMMIT'
        EXPORTING
          wait = abap_true.
    ENDIF.

    LOOP AT ct_change ASSIGNING <ls_change>.
      <ls_change>-msgty = 'S'.
      IF p_test = abap_true.
        MESSAGE s102 WITH <ls_change>-bwtar_old <ls_change>-bwtar_new
                INTO <ls_change>-message.
      ELSE.
        MESSAGE s101 WITH <ls_change>-bwtar_old <ls_change>-bwtar_new
                INTO <ls_change>-message.
      ENDIF.
    ENDLOOP.
    mv_changed = mv_changed + lines( ct_change ).

  ENDMETHOD.


  METHOD get_fiscal_year.

    READ TABLE mt_year_buffer ASSIGNING FIELD-SYMBOL(<ls_buf>)
         WITH TABLE KEY bukrs = iv_bukrs.
    IF sy-subrc <> 0.
      INSERT VALUE #( bukrs = iv_bukrs )
             INTO TABLE mt_year_buffer ASSIGNING <ls_buf>.

      CALL FUNCTION 'FI_PERIOD_DETERMINE'
        EXPORTING
          i_budat = mv_date
          i_bukrs = iv_bukrs
        IMPORTING
          e_gjahr = <ls_buf>-gjahr
        EXCEPTIONS
          OTHERS  = 1.
      IF sy-subrc <> 0.
        CLEAR <ls_buf>-gjahr.   " no calendar year fallback - item error
      ENDIF.
    ENDIF.

    rv_gjahr = <ls_buf>-gjahr.

  ENDMETHOD.


  METHOD get_valtype_from_table.

    " 1. Entry for the material type
    IF iv_mtart IS NOT INITIAL.
      rv_bwtar = read_valtype( iv_werks = iv_werks
                               iv_mtart = iv_mtart
                               iv_gjahr = iv_gjahr ).
    ENDIF.

    " 2. Plant default: entry with blank material type
    IF rv_bwtar IS INITIAL.
      rv_bwtar = read_valtype( iv_werks = iv_werks
                               iv_mtart = space
                               iv_gjahr = iv_gjahr ).
    ENDIF.

  ENDMETHOD.


  METHOD read_valtype.

    READ TABLE mt_valtype_buffer ASSIGNING FIELD-SYMBOL(<ls_buf>)
         WITH TABLE KEY werks = iv_werks
                        mtart = iv_mtart
                        gjahr = iv_gjahr.
    IF sy-subrc <> 0.
      INSERT VALUE #( werks = iv_werks mtart = iv_mtart gjahr = iv_gjahr )
             INTO TABLE mt_valtype_buffer ASSIGNING <ls_buf>.

      SELECT SINGLE bwtar
        FROM zptp_po_valtype
        WHERE werks = @iv_werks
          AND mtart = @iv_mtart
          AND gjahr = @iv_gjahr
        INTO @<ls_buf>-bwtar.               " stays initial if not found
    ENDIF.

    rv_bwtar = <ls_buf>-bwtar.

  ENDMETHOD.


  METHOD valtype_exists.

    READ TABLE mt_mbew_buffer ASSIGNING FIELD-SYMBOL(<ls_buf>)
         WITH TABLE KEY matnr = iv_matnr
                        bwkey = iv_bwkey
                        bwtar = iv_bwtar.
    IF sy-subrc <> 0.
      INSERT VALUE #( matnr = iv_matnr bwkey = iv_bwkey bwtar = iv_bwtar )
             INTO TABLE mt_mbew_buffer ASSIGNING <ls_buf>.

      " Records flagged for deletion do not count
      SELECT SINGLE @abap_true
        FROM mbew
        WHERE matnr = @iv_matnr
          AND bwkey = @iv_bwkey
          AND bwtar = @iv_bwtar
          AND lvorm = @space
        INTO @<ls_buf>-exists.              " stays abap_false if not found
    ENDIF.

    rv_exists = <ls_buf>-exists.

  ENDMETHOD.


  METHOD display_log.

    " Only changed items and errors are listed; in background the list
    " goes to the spool of the job
    IF mt_log IS INITIAL.
      RETURN.
    ENDIF.

    TRY.
        cl_salv_table=>factory( IMPORTING r_salv_table = DATA(lo_alv)
                                CHANGING  t_table      = mt_log ).

        lo_alv->get_functions( )->set_all( abap_true ).

        DATA(lo_columns) = lo_alv->get_columns( ).
        lo_columns->set_optimize( abap_true ).
        set_column_text( io_columns = lo_columns
                         iv_name    = 'BWTAR_OLD'
                         iv_short   = 'Old VType'(t01)
                         iv_medium  = 'Old valuation type'(t02) ).
        set_column_text( io_columns = lo_columns
                         iv_name    = 'BWTAR_NEW'
                         iv_short   = 'New VType'(t03)
                         iv_medium  = 'New valuation type'(t04) ).

        lo_alv->display( ).

      CATCH cx_salv_msg cx_salv_not_found INTO DATA(lx_salv).
        MESSAGE lx_salv TYPE 'I'.
    ENDTRY.

  ENDMETHOD.


  METHOD set_column_text.

    DATA(lo_column) = io_columns->get_column( iv_name ).
    lo_column->set_short_text( iv_short ).
    lo_column->set_medium_text( iv_medium ).
    lo_column->set_long_text( CONV #( iv_medium ) ).

  ENDMETHOD.

ENDCLASS.


AT SELECTION-SCREEN OUTPUT.
  " P_DATE is only ready for input with the option "key date"
  LOOP AT SCREEN.
    IF screen-group1 = 'KEY'.
      screen-input = COND #( WHEN p_key = abap_true THEN 1 ELSE 0 ).
      MODIFY SCREEN.
    ENDIF.
  ENDLOOP.


AT SELECTION-SCREEN.
  " Only on execution - not when switching the radio buttons
  IF p_key = abap_true
  AND p_date IS INITIAL
  AND ( sy-ucomm = 'ONLI' OR sy-ucomm = 'SJOB' OR sy-batch = abap_true ).
    MESSAGE e105.
  ENDIF.


START-OF-SELECTION.
  NEW lcl_app( )->run( ).
