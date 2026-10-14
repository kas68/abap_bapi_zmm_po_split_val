*---------------------------------------------------------------------*
* Report ZPTP_PROD_BATCH_VALTYPE
* Sets the valuation type (MCHA-BWTAR) in the batch master of the
* batches of open production order items, mainly for background jobs.
* Open item = output item (AFPO) of a production order (AUTYP 10) in
* plant P_WERKS; order and item not deleted, not delivery completed,
* no goods receipt (WEMNG = 0), batch filled (AFPO-CHARG).
* Only split-valuated materials (MBEW header record with BWTTY).
* Valuation type from table ZPTP_301_VALTYPE (same rules as BAdI class
* ZCL_IM_MM_PO_SPLIT_VAL and report ZPTP_PO_SPLIT_VAL_UPDATE):
*   1. plant + material type (MARA-MTART) + year
*   2. plant + blank material type + year
*   3. blank plant + material type + year
*   4. blank plant + blank material type + year (global default)
* Year = fiscal year of the key date in the order's company code. Key
* date = run date of the program (P_RUN, SY-DATLO) or P_DATE (P_KEY).
* The batch is changed only if its valuation type differs from the
* table value, the new valuation type has its own valuation record
* (MBEW, not flagged for deletion) and the batch has no stock in the
* plant of any stock type: storage location stock (MCHB) and special
* stocks (MSKA, MSPR, MSLB, MKOL, MSKU). Each batch is processed once,
* even if several order items use it.
* Update with BAPI_BATCH_CHANGE, one call and commit per batch. Test
* run = no BAPI call; all checks are done.
* Messages: class ZPTP_SPLIT_VAL, 100, 105 - 107, 110 - 116.
*---------------------------------------------------------------------*
REPORT zptp_prod_batch_valtype MESSAGE-ID zptp_split_val.

TABLES afpo.

PARAMETERS p_werks TYPE werks_d OBLIGATORY.

SELECT-OPTIONS: s_aufnr FOR afpo-aufnr,
                s_matnr FOR afpo-matnr.

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
        aufnr TYPE aufnr,
        posnr TYPE co_posnr,
        bukrs TYPE bukrs,
        werks TYPE werks_d,
        matnr TYPE matnr,
        charg TYPE charg_d,
        mtart TYPE mtart,
        bwkey TYPE bwkey,
      END OF ty_item,
      tt_item TYPE STANDARD TABLE OF ty_item WITH EMPTY KEY,

      BEGIN OF ty_log,
        msgty     TYPE bapi_mtype,
        aufnr     TYPE aufnr,
        posnr     TYPE co_posnr,
        werks     TYPE werks_d,
        matnr     TYPE matnr,
        charg     TYPE charg_d,
        mtart     TYPE mtart,
        gjahr     TYPE gjahr,
        bwtar_old TYPE bwtar_d,
        bwtar_new TYPE bwtar_d,
        message   TYPE bapi_msg,
      END OF ty_log,
      tt_log TYPE STANDARD TABLE OF ty_log WITH EMPTY KEY,

      BEGIN OF ty_batch_key,
        matnr TYPE matnr,
        werks TYPE werks_d,
        charg TYPE charg_d,
      END OF ty_batch_key,
      tt_batch_key TYPE HASHED TABLE OF ty_batch_key
                   WITH UNIQUE KEY matnr werks charg,

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
    DATA mt_done           TYPE tt_batch_key.
    DATA mt_year_buffer    TYPE tt_year_buffer.
    DATA mt_valtype_buffer TYPE tt_valtype_buffer.
    DATA mt_mbew_buffer    TYPE tt_mbew_buffer.

    " Counters per batch (not per order item)
    DATA mv_selected    TYPE i.
    DATA mv_changed     TYPE i.
    DATA mv_unchanged   TYPE i.
    DATA mv_not_changed TYPE i.

    METHODS select_items
      RETURNING VALUE(rt_item) TYPE tt_item.

    "! Checks one batch and changes it if needed; returns the log line
    METHODS process_batch
      IMPORTING is_item       TYPE ty_item
      RETURNING VALUE(rs_log) TYPE ty_log.

    "! Any stock of the batch in the plant, all stock types
    METHODS has_stock
      IMPORTING is_item          TYPE ty_item
      RETURNING VALUE(rv_stock) TYPE abap_bool.

    "! BAPI_BATCH_CHANGE with commit; fills type and message of the log
    METHODS change_batch
      IMPORTING is_item TYPE ty_item
      CHANGING  cs_log  TYPE ty_log.

    "! Fiscal year of the key date; initial if it cannot be determined
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

    mv_date = COND #( WHEN p_key = abap_true THEN p_date
                      ELSE sy-datlo ).

    DATA(lt_item) = select_items( ).

    IF lt_item IS INITIAL.
      MESSAGE s110.
      RETURN.
    ENDIF.

    LOOP AT lt_item ASSIGNING FIELD-SYMBOL(<ls_item>).

      " Order item without batch: nothing to change, listed as warning
      IF <ls_item>-charg IS INITIAL.
        APPEND VALUE #( msgty = 'W'
                        aufnr = <ls_item>-aufnr
                        posnr = <ls_item>-posnr
                        werks = <ls_item>-werks
                        matnr = <ls_item>-matnr
                        mtart = <ls_item>-mtart ) TO mt_log
               ASSIGNING FIELD-SYMBOL(<ls_log>).
        MESSAGE w111 INTO <ls_log>-message.
        CONTINUE.
      ENDIF.

      " Each batch once, also if several order items use it
      INSERT VALUE #( matnr = <ls_item>-matnr
                      werks = <ls_item>-werks
                      charg = <ls_item>-charg ) INTO TABLE mt_done.
      IF sy-subrc <> 0.
        CONTINUE.
      ENDIF.

      mv_selected = mv_selected + 1.

      DATA(ls_log) = process_batch( <ls_item> ).
      CASE ls_log-msgty.
        WHEN space.
          mv_unchanged = mv_unchanged + 1.     " already correct, not logged
        WHEN 'S'.
          mv_changed = mv_changed + 1.
          APPEND ls_log TO mt_log.
        WHEN OTHERS.
          mv_not_changed = mv_not_changed + 1.
          APPEND ls_log TO mt_log.
      ENDCASE.

    ENDLOOP.

    " Summary - goes to the job log in background
    MESSAGE s116 WITH mv_selected mv_changed mv_unchanged mv_not_changed.

    display_log( ).

  ENDMETHOD.


  METHOD select_items.

    " Output items (AFPO) of production orders - components are in RESB
    " and not read. Split-valuated materials only: header valuation
    " record (BWTAR = space) with a valuation category.
    " Open item: order and item not deleted, not delivery completed
    " (also set by TECO), no goods receipt quantity.
    SELECT a~aufnr, a~posnr, k~bukrs, a~dwerk AS werks, a~matnr,
           a~charg, m~mtart, w~bwkey
      FROM aufk AS k
      INNER JOIN afpo  AS a ON a~aufnr = k~aufnr
      INNER JOIN mara  AS m ON m~matnr = a~matnr
      INNER JOIN t001w AS w ON w~werks = a~dwerk
      INNER JOIN mbew  AS v ON  v~matnr = a~matnr
                            AND v~bwkey = w~bwkey
                            AND v~bwtar = @space
      WHERE k~autyp = '10'
        AND k~loekz = @space
        AND a~dwerk = @p_werks
        AND a~aufnr IN @s_aufnr
        AND a~matnr IN @s_matnr
        AND a~xloek = @space
        AND a~elikz = @space
        AND a~wemng = 0
        AND v~bwtty <> @space
      ORDER BY a~aufnr, a~posnr
      INTO CORRESPONDING FIELDS OF TABLE @rt_item.

  ENDMETHOD.


  METHOD process_batch.

    rs_log = VALUE #( aufnr = is_item-aufnr
                      posnr = is_item-posnr
                      werks = is_item-werks
                      matnr = is_item-matnr
                      charg = is_item-charg
                      mtart = is_item-mtart ).

    " Batch master in the plant
    SELECT SINGLE bwtar
      FROM mcha
      WHERE matnr = @is_item-matnr
        AND werks = @is_item-werks
        AND charg = @is_item-charg
      INTO @rs_log-bwtar_old.
    IF sy-subrc <> 0.
      rs_log-msgty = 'E'.
      MESSAGE e112 WITH is_item-charg |{ is_item-matnr ALPHA = OUT }|
                        is_item-werks
              INTO rs_log-message.
      RETURN.
    ENDIF.

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
      MESSAGE e107 WITH is_item-werks is_item-mtart rs_log-gjahr
              INTO rs_log-message.
      RETURN.
    ENDIF.

    " Already correct: MSGTY stays initial
    IF rs_log-bwtar_new = rs_log-bwtar_old.
      RETURN.
    ENDIF.

    " Valuation record must exist, otherwise GR will fail
    IF valtype_exists( iv_matnr = is_item-matnr
                       iv_bwkey = is_item-bwkey
                       iv_bwtar = rs_log-bwtar_new ) = abap_false.
      rs_log-msgty = 'E'.
      MESSAGE e106 WITH rs_log-bwtar_new |{ is_item-matnr ALPHA = OUT }|
                        is_item-werks
              INTO rs_log-message.
      RETURN.
    ENDIF.

    " The valuation type of a batch with stock must not be changed
    IF has_stock( is_item ) = abap_true.
      rs_log-msgty = 'W'.
      MESSAGE w113 WITH is_item-charg is_item-werks
              INTO rs_log-message.
      RETURN.
    ENDIF.

    IF p_test = abap_true.
      rs_log-msgty = 'S'.
      MESSAGE s115 WITH rs_log-bwtar_old rs_log-bwtar_new
              INTO rs_log-message.
      RETURN.
    ENDIF.

    change_batch( EXPORTING is_item = is_item
                  CHANGING  cs_log  = rs_log ).

  ENDMETHOD.


  METHOD has_stock.

    " All stock types of the batch in the plant, own and special stocks.
    " Each read stops the check at the first stock found.

    " Storage location stock: unrestricted, in transfer, quality
    " inspection, restricted, blocked, blocked returns
    SELECT SINGLE @abap_true
      FROM mchb
      WHERE matnr = @is_item-matnr
        AND werks = @is_item-werks
        AND charg = @is_item-charg
        AND ( clabs <> 0 OR cumlm <> 0 OR cinsm <> 0
           OR ceinm <> 0 OR cspem <> 0 OR cretm <> 0 )
      INTO @rv_stock.                       " stays abap_false if not found
    IF rv_stock = abap_true.
      RETURN.
    ENDIF.

    " Sales order stock (special stock E)
    SELECT SINGLE @abap_true
      FROM mska
      WHERE matnr = @is_item-matnr
        AND werks = @is_item-werks
        AND charg = @is_item-charg
        AND ( kalab <> 0 OR kains <> 0 OR kaspe <> 0 OR kaein <> 0 )
      INTO @rv_stock.
    IF rv_stock = abap_true.
      RETURN.
    ENDIF.

    " Project stock (special stock Q)
    SELECT SINGLE @abap_true
      FROM mspr
      WHERE matnr = @is_item-matnr
        AND werks = @is_item-werks
        AND charg = @is_item-charg
        AND ( prlab <> 0 OR prins <> 0 OR prspe <> 0 OR prein <> 0 )
      INTO @rv_stock.
    IF rv_stock = abap_true.
      RETURN.
    ENDIF.

    " Stock provided to vendor (special stock O)
    SELECT SINGLE @abap_true
      FROM mslb
      WHERE matnr = @is_item-matnr
        AND werks = @is_item-werks
        AND charg = @is_item-charg
        AND ( lblab <> 0 OR lbins <> 0 OR lbein <> 0 OR lbuml <> 0 )
      INTO @rv_stock.
    IF rv_stock = abap_true.
      RETURN.
    ENDIF.

    " Vendor consignment / pipeline stock (special stock K, P)
    SELECT SINGLE @abap_true
      FROM mkol
      WHERE matnr = @is_item-matnr
        AND werks = @is_item-werks
        AND charg = @is_item-charg
        AND ( slabs <> 0 OR sinsm <> 0 OR seinm <> 0 OR sspem <> 0 )
      INTO @rv_stock.
    IF rv_stock = abap_true.
      RETURN.
    ENDIF.

    " Stock at customer: consignment, returnable packaging (special
    " stock W, V)
    SELECT SINGLE @abap_true
      FROM msku
      WHERE matnr = @is_item-matnr
        AND werks = @is_item-werks
        AND charg = @is_item-charg
        AND ( kulab <> 0 OR kuins <> 0 OR kuein <> 0 )
      INTO @rv_stock.

  ENDMETHOD.


  METHOD change_batch.

    DATA ls_attr   TYPE bapibatchatt.
    DATA ls_attrx  TYPE bapibatchattx.
    DATA lt_return TYPE STANDARD TABLE OF bapiret2.

    ls_attr-val_type  = cs_log-bwtar_new.
    ls_attrx-val_type = abap_true.

    " The BAPI locks the batch; a lock by another user is returned as
    " an error message
    CALL FUNCTION 'BAPI_BATCH_CHANGE'
      EXPORTING
        material         = is_item-matnr
        batch            = is_item-charg
        plant            = is_item-werks
        batchattributes  = ls_attr
        batchattributesx = ls_attrx
      TABLES
        return           = lt_return.

    LOOP AT lt_return INTO DATA(ls_return)
         WHERE type = 'E' OR type = 'A'.
      EXIT.
    ENDLOOP.

    IF sy-subrc = 0.
      CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
      cs_log-msgty   = 'E'.
      cs_log-message = ls_return-message.
      RETURN.
    ENDIF.

    CALL FUNCTION 'BAPI_TRANSACTION_COMMIT'
      EXPORTING
        wait = abap_true.

    cs_log-msgty = 'S'.
    MESSAGE s114 WITH cs_log-bwtar_old cs_log-bwtar_new
            INTO cs_log-message.

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
        CLEAR <ls_buf>-gjahr.   " no calendar year fallback - batch error
      ENDIF.
    ENDIF.

    rv_gjahr = <ls_buf>-gjahr.

  ENDMETHOD.


  METHOD get_valtype_from_table.

    " Most specific entry wins; blank WERKS / MTART = all plants / types
    " 1. plant + material type
    IF iv_mtart IS NOT INITIAL.
      rv_bwtar = read_valtype( iv_werks = iv_werks
                               iv_mtart = iv_mtart
                               iv_gjahr = iv_gjahr ).
    ENDIF.

    " 2. plant, all material types
    IF rv_bwtar IS INITIAL.
      rv_bwtar = read_valtype( iv_werks = iv_werks
                               iv_mtart = space
                               iv_gjahr = iv_gjahr ).
    ENDIF.

    " 3. all plants, material type
    IF rv_bwtar IS INITIAL AND iv_mtart IS NOT INITIAL.
      rv_bwtar = read_valtype( iv_werks = space
                               iv_mtart = iv_mtart
                               iv_gjahr = iv_gjahr ).
    ENDIF.

    " 4. all plants, all material types
    IF rv_bwtar IS INITIAL.
      rv_bwtar = read_valtype( iv_werks = space
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
        FROM zptp_301_valtype
        WHERE werks = @iv_werks
          AND mtart = @iv_mtart
          AND gjahr = @iv_gjahr
          AND active = @abap_true
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

    " Only changed batches, warnings and errors are listed; in background
    " the list goes to the spool of the job
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
