*---------------------------------------------------------------------*
* Report ZPTP_VALTYPE_DOCSALIGN
* Aligns the valuation type (BWTAR) of open purchase order items, of
* their open inbound deliveries and of the batches on these deliveries
* with table ZPTP_301_VALTYPE.
* Valuation type from ZPTP_301_VALTYPE, same lookup order as
* BAdI class ZCL_IM_MM_PO_SPLIT_VAL (plant + material type, plant,
* material type, global default; only ACTIVE entries). Year = fiscal year of the
* run date (SY-DATLO) in the item's company code.
* Open item = standard PO (BSTYP F), PO and item not deleted, not
* delivery completed, no return item, quantity still to be received on
* a schedule line (EKET-MENGE > EKET-WEMNG), no goods receipt yet
* (no schedule line with EKET-WEMNG > 0). Only split-valuated
* materials; the new valuation type must have its own valuation record
* (MBEW, not flagged for deletion).
* Scenario 1 - item without inbound delivery: PO item updated only.
* Scenario 2 - item with inbound deliveries (EKES-VBELN). Only delivery
*   items without goods receipt (LIPS-WBSTA <> C) are processed:
*   2.1 with a new batch (no material movement of the batch in the
*       plant, MSEG): the batch master (MCHA-BWTAR) is changed first if
*       it differs (BAPI_BATCH_CHANGE), then the delivery item;
*   2.2 without batch: the delivery item only;
*   2.3 with an existing batch (any material movement in the plant):
*       the batch master is not changed. Its valuation type replaces
*       the table value for the PO item and all its delivery items
*       (also new batches of the item). Existing batches of one PO
*       item with different valuation types: item error (133).
*   Delivery item (LIPS-BWTAR) changed with WS_DELIVERY_UPDATE_2, one
*   call per delivery. Then the PO item, only if all its open delivery
*   items are aligned - so it gets the valuation type of its deliveries.
* PO items: BAPI_PO_CHANGE, one call per PO, without output
* determination (NO_MESSAGING).
* Flow = PO item, its open delivery items and their batches. When one
*   object of a flow is listed, the objects of the flow already correct
*   are listed too (136, no light) - never changed, never posted.
*   Option P_ALIGN: flows already aligned are listed as well (136).
* Items with a goods receipt (partially or fully received) are never
*   changed, nor their deliveries and batches. Option P_GR lists them
*   (130), online not postable (131), with the last goods receipt
*   document in an extra column.
* Test run: no batch or delivery change; BAPI_PO_CHANGE with TESTRUN.
* After each real change the object is read again from the database
* (MCHA, LIPS, EKPO); only a confirmed change is green in the ALV,
* otherwise the line is an error (129). Valuation type taken from an
* existing batch: orange in the ALV instead of yellow (proposals; on the
* batch line its old / new valuation type).
* Run modes:
*   Background - all changes in one run, as described above (also for
*     background jobs); list of changes and errors at the end.
*   Online - simulation (as a test run), then ALV with the proposed
*     changes. The user selects rows and posts them with function POST
*     (GUI status ZSALV_POST); per selection batches first, then
*     deliveries, then PO items. A delivery item needs its batch, a PO
*     item all its open delivery items with the new valuation type.
*     Failed rows can be posted again. Not possible in background.
* S/4HANA: goods movement status in LIPS-WBSTA (ECC: VBUP-WBSTA).
* Messages: class ZPTP_SPLIT_VAL, 100 - 104, 106, 107, 117 - 136.
*---------------------------------------------------------------------*
REPORT zptp_valtype_docsalign MESSAGE-ID zptp_split_val.

TABLES: ekpo, likp.

SELECTION-SCREEN BEGIN OF BLOCK b01 WITH FRAME TITLE TEXT-b01.
SELECT-OPTIONS: s_werks FOR ekpo-werks DEFAULT '8Q01',
                s_ebeln FOR ekpo-ebeln,
                " PO items with an inbound delivery in the range - their
                " whole flow is processed (all open delivery items)
                s_vbeln FOR likp-vbeln.
" Items with goods receipt and nothing to receive: listed, not changed
PARAMETERS p_gr AS CHECKBOX DEFAULT abap_false.
" Flows already aligned (no object to change): listed (136), display only
PARAMETERS p_align AS CHECKBOX DEFAULT abap_false.
SELECTION-SCREEN END OF BLOCK b01.

" Background = as before; Online = proposals posted row by row from ALV
SELECTION-SCREEN BEGIN OF BLOCK b02 WITH FRAME TITLE TEXT-b02.
" USER-COMMAND must stay on the first button of the group
PARAMETERS: p_bgd RADIOBUTTON GROUP mode USER-COMMAND mode,
            p_onl RADIOBUTTON GROUP mode DEFAULT 'X'.
PARAMETERS p_test AS CHECKBOX DEFAULT abap_true MODIF ID tst.
SELECTION-SCREEN END OF BLOCK b02.


CLASS lcl_app DEFINITION FINAL.

  PUBLIC SECTION.
    METHODS run.

  PRIVATE SECTION.

    TYPES:
      ty_scen   TYPE c LENGTH 3,
      ty_object TYPE c LENGTH 10,
      ty_source TYPE c LENGTH 5,

      BEGIN OF ty_item,
        ebeln         TYPE ebeln,
        ebelp         TYPE ebelp,
        bukrs         TYPE bukrs,
        werks         TYPE werks_d,
        matnr         TYPE matnr,
        bwtar         TYPE bwtar_d,
        mtart         TYPE mtart,
        bwkey         TYPE bwkey,
        scen          TYPE ty_scen,
        gjahr         TYPE gjahr,
        bwtar_new     TYPE bwtar_d,
        failed        TYPE abap_bool,   " determination error, logged
        blocked_vbeln TYPE vbeln_vl,    " first delivery not aligned
        blocked_posnr TYPE posnr_vl,
        gr_only       TYPE abap_bool,   " P_GR: goods receipt, listed only
        bwtar_ref     TYPE bwtar_d,     " valuation type of existing batch
        ref_charg     TYPE charg_d,     " batch giving BWTAR_REF
        ref_error     TYPE bapi_msg,    " existing batches inconsistent
        source        TYPE ty_source,   " origin of BWTAR_NEW
      END OF ty_item,
      tt_item TYPE SORTED TABLE OF ty_item WITH UNIQUE KEY ebeln ebelp,

      BEGIN OF ty_dlv,
        vbeln TYPE vbeln_vl,
        posnr TYPE posnr_vl,
        uecha TYPE uecha,
        vgbel TYPE vgbel,
        vgpos TYPE vgpos,
        ebeln TYPE ebeln,
        ebelp TYPE ebelp,
        matnr TYPE matnr,
        werks TYPE werks_d,
        charg TYPE charg_d,
        bwtar TYPE bwtar_d,
      END OF ty_dlv,
      tt_dlv TYPE STANDARD TABLE OF ty_dlv WITH EMPTY KEY,

      BEGIN OF ty_log,
        msgty     TYPE bapi_mtype,
        scen      TYPE ty_scen,
        object    TYPE ty_object,
        ebeln     TYPE ebeln,
        ebelp     TYPE ebelp,
        vbeln     TYPE vbeln_vl,
        posnr     TYPE posnr_vl,
        werks     TYPE werks_d,
        matnr     TYPE matnr,
        charg     TYPE charg_d,
        mtart     TYPE mtart,
        gjahr     TYPE gjahr,
        bwtar_old TYPE bwtar_d,
        bwtar_new TYPE bwtar_d,
        source    TYPE ty_source,   " table or existing batch
        message   TYPE bapi_msg,
        todo      TYPE abap_bool,   " online: proposal not posted yet
        posted    TYPE abap_bool,   " online: posted from the ALV
        gr_only   TYPE abap_bool,   " P_GR: goods receipt, never posted
        verified  TYPE abap_bool,   " new value read back from the DB
        nochange  TYPE abap_bool,   " already correct, listed for the flow
        logidx    TYPE i,           " online: line of MT_LOG
      END OF ty_log,
      tt_log TYPE STANDARD TABLE OF ty_log WITH EMPTY KEY,

      " ALV line: one old / new pair per object, T_COLOR = cell colours
      BEGIN OF ty_out,
        werks         TYPE werks_d,
        light         TYPE c LENGTH 1,  " 1 red, 2 yellow, 3 green
        ebeln         TYPE ebeln,
        object        TYPE ty_object,
        ebelp         TYPE ebelp,
        vbeln         TYPE vbeln_vl,
        posnr         TYPE posnr_vl,
        mblnr         TYPE mblnr,       " P_GR: last goods receipt
        matnr         TYPE matnr,
        charg         TYPE charg_d,
        mtart         TYPE mtart,
        gjahr         TYPE gjahr,
        po_bwtar_old  TYPE bwtar_d,
        po_bwtar_new  TYPE bwtar_d,
        dlv_bwtar_old TYPE bwtar_d,
        dlv_bwtar_new TYPE bwtar_d,
        bat_bwtar_old TYPE bwtar_d,
        bat_bwtar_new TYPE bwtar_d,
        bat_used      TYPE abap_bool,   " batch with material movement
        source        TYPE ty_source,
        scen          TYPE ty_scen,     " ALV column order = field order
        message       TYPE bapi_msg,
        msgty         TYPE bapi_mtype,
        posted        TYPE abap_bool,
        logidx        TYPE i,           " line of MT_LOG (ALV sorts)
        seq           TYPE i,           " order within the PO (hidden)
        rank          TYPE i,           " 1 batch, 2 delivery, 3 PO item
        t_color       TYPE lvc_t_scol,
      END OF ty_out,
      tt_out TYPE STANDARD TABLE OF ty_out WITH EMPTY KEY,

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
                     WITH UNIQUE KEY matnr bwkey bwtar,

      BEGIN OF ty_batch_buffer,
        matnr TYPE matnr,
        werks TYPE werks_d,
        charg TYPE charg_d,
        found TYPE abap_bool,   " batch master exists (MCHA)
        bwtar TYPE bwtar_d,     " MCHA-BWTAR at selection
        used  TYPE abap_bool,   " material movement in the plant
        done  TYPE abap_bool,   " checked / changed in this run
        ok    TYPE abap_bool,
      END OF ty_batch_buffer,
      tt_batch_buffer TYPE HASHED TABLE OF ty_batch_buffer
                      WITH UNIQUE KEY matnr werks charg,

      BEGIN OF ty_gr_doc,
        ebeln TYPE ebeln,
        ebelp TYPE ebelp,
        mblnr TYPE mblnr,
      END OF ty_gr_doc,
      tt_gr_doc TYPE HASHED TABLE OF ty_gr_doc WITH UNIQUE KEY ebeln ebelp.

    CONSTANTS:
      BEGIN OF c_scen,
        po       TYPE ty_scen VALUE '1',
        delivery TYPE ty_scen VALUE '2',
        batch    TYPE ty_scen VALUE '2.1',
        no_batch TYPE ty_scen VALUE '2.2',
        used     TYPE ty_scen VALUE '2.3',  " existing batch, reference
      END OF c_scen,
      BEGIN OF c_source,
        table TYPE ty_source VALUE 'TABLE',
        batch TYPE ty_source VALUE 'BATCH',
      END OF c_source,
      BEGIN OF c_object,
        po_item  TYPE ty_object VALUE 'PO ITEM',
        delivery TYPE ty_object VALUE 'DELIVERY',
        batch    TYPE ty_object VALUE 'BATCH',
      END OF c_object,
      " Copy of status STANDARD_FULLSCREEN (SAPLSLVC_FULLSCREEN) + POST
      c_status     TYPE sypfkey          VALUE 'ZSALV_POST',
      c_fcode_post TYPE salv_de_function VALUE 'POST'.

    "! Run date - base of the fiscal year
    DATA mv_date TYPE d.

    "! Simulation: P_TEST in background mode, always on for the online
    "! proposal, off when posting from the ALV
    DATA mv_test TYPE abap_bool.

    DATA mo_alv TYPE REF TO cl_salv_table.

    DATA mt_log            TYPE tt_log.
    DATA mt_out            TYPE tt_out.
    DATA mt_year_buffer    TYPE tt_year_buffer.
    DATA mt_valtype_buffer TYPE tt_valtype_buffer.
    DATA mt_mbew_buffer    TYPE tt_mbew_buffer.
    DATA mt_batch_buffer   TYPE tt_batch_buffer.
    DATA mt_gr_doc         TYPE tt_gr_doc.

    " PO item counters
    DATA mv_selected  TYPE i.
    DATA mv_changed   TYPE i.
    DATA mv_unchanged TYPE i.
    DATA mv_errors    TYPE i.

    " Delivery item counters
    DATA mv_dlv_selected  TYPE i.
    DATA mv_dlv_changed   TYPE i.
    DATA mv_batch_changed TYPE i.
    DATA mv_dlv_errors    TYPE i.

    "! Items without goods receipt; P_GR: also items with one (GR_ONLY)
    METHODS select_items
      RETURNING VALUE(rt_item) TYPE tt_item.

    "! S_VBELN: only PO items with an inbound delivery in the range
    METHODS filter_by_delivery
      CHANGING ct_item TYPE tt_item.

    "! P_GR: last goods receipt document per item (MT_GR_DOC)
    METHODS read_gr_documents
      IMPORTING it_item TYPE tt_item.

    "! P_GR: received items logged (130) and removed - never changed
    METHODS list_received_items
      CHANGING ct_item TYPE tt_item.

    "! Open inbound delivery items of the PO items; sets the scenario
    METHODS select_deliveries
      EXPORTING et_dlv  TYPE tt_dlv
      CHANGING  ct_item TYPE tt_item.

    "! Batch masters of the delivery items and their material movements
    METHODS read_batches
      IMPORTING it_dlv TYPE tt_dlv.

    "! Valuation type of existing batches as reference of the PO item
    METHODS set_batch_reference
      IMPORTING it_dlv  TYPE tt_dlv
      CHANGING  ct_item TYPE tt_item.

    "! Batch with a material movement in the plant (see READ_BATCHES)
    METHODS is_batch_used
      IMPORTING is_dlv         TYPE ty_dlv
      RETURNING VALUE(rv_used) TYPE abap_bool.

    "! Log line with the new valuation type, or MSGTY = E on error
    METHODS determine
      IMPORTING is_item       TYPE ty_item
      RETURNING VALUE(rs_log) TYPE ty_log.

    "! Scenario 2: batches first, then one change per delivery
    METHODS align_deliveries
      IMPORTING it_dlv  TYPE tt_dlv
      CHANGING  ct_item TYPE tt_item.

    "! Batch master valuation type; abap_true if aligned (buffered)
    METHODS align_batch
      IMPORTING is_dlv       TYPE ty_dlv
                is_item      TYPE ty_item
      RETURNING VALUE(rv_ok) TYPE abap_bool.

    METHODS change_batch
      CHANGING cs_log TYPE ty_log.

    "! One WS_DELIVERY_UPDATE_2 call for all items of the delivery
    METHODS change_delivery
      IMPORTING iv_vbeln  TYPE vbeln_vl
      CHANGING  ct_change TYPE tt_log.

    "! PO item not changed while one of its deliveries is not aligned
    METHODS block_item
      IMPORTING iv_vbeln TYPE vbeln_vl
                iv_posnr TYPE posnr_vl
      CHANGING  cs_item  TYPE ty_item.

    "! Objects already correct in a listed flow (136) - after all changes
    METHODS list_unchanged
      IMPORTING it_dlv  TYPE tt_dlv
                it_item TYPE tt_item.

    METHODS update_purchase_orders
      IMPORTING it_item TYPE tt_item.

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

    "! ALV lines from MT_LOG; new value yellow (proposed / test run) or
    "! green (change confirmed on the database)
    METHODS build_output.

    METHODS on_added_function
      FOR EVENT added_function OF cl_salv_events_table
      IMPORTING e_salv_function.

    "! Online: posts the selected proposals (IT_ROWS = lines of MT_LOG)
    METHODS post_selected
      IMPORTING it_rows TYPE salv_t_row.

    METHODS post_batches
      CHANGING ct_post TYPE tt_log.

    "! Delivery items with a batch only if the batch is aligned
    METHODS post_deliveries
      CHANGING ct_post TYPE tt_log.

    "! PO items with deliveries only if all open items are aligned
    METHODS post_purchase_orders
      CHANGING ct_post TYPE tt_log.

    METHODS set_column_text
      IMPORTING io_columns TYPE REF TO cl_salv_columns_table
                iv_name    TYPE lvc_fname
                iv_short   TYPE csequence    " text symbols of any
                iv_medium  TYPE csequence    " maximum length
                iv_long    TYPE csequence OPTIONAL  " default: medium
      RAISING   cx_salv_not_found.

ENDCLASS.


CLASS lcl_app IMPLEMENTATION.

  METHOD run.

    " The online mode needs a user to select and post the rows
    IF p_onl = abap_true AND sy-batch = abap_true.
      MESSAGE e126.
    ENDIF.

    mv_date = sy-datlo.
    mv_test = COND #( WHEN p_onl = abap_true THEN abap_true ELSE p_test ).

    DATA(lt_item) = select_items( ).

    IF s_vbeln[] IS NOT INITIAL.
      filter_by_delivery( CHANGING ct_item = lt_item ).
    ENDIF.

    IF lt_item IS INITIAL.
      MESSAGE s104.
      RETURN.
    ENDIF.

    IF p_gr = abap_true.
      read_gr_documents( lt_item ).
      list_received_items( CHANGING ct_item = lt_item ).
    ENDIF.

    mv_selected = lines( lt_item ).

    select_deliveries( IMPORTING et_dlv  = DATA(lt_dlv)
                       CHANGING  ct_item = lt_item ).

    " Existing batches give the valuation type instead of the table
    read_batches( lt_dlv ).
    set_batch_reference( EXPORTING it_dlv  = lt_dlv
                         CHANGING  ct_item = lt_item ).

    LOOP AT lt_item ASSIGNING FIELD-SYMBOL(<ls_item>).
      DATA(ls_log) = determine( <ls_item> ).
      <ls_item>-gjahr     = ls_log-gjahr.
      <ls_item>-bwtar_new = ls_log-bwtar_new.
      <ls_item>-source    = ls_log-source.
      IF ls_log-msgty = 'E'.
        <ls_item>-failed = abap_true.
        mv_errors = mv_errors + 1.
        APPEND ls_log TO mt_log.
      ENDIF.
    ENDLOOP.

    " Batches and deliveries before the PO items
    align_deliveries( EXPORTING it_dlv  = lt_dlv
                      CHANGING  ct_item = lt_item ).

    update_purchase_orders( lt_item ).

    " Display only - added after processing, so never changed
    list_unchanged( it_dlv  = lt_dlv
                    it_item = lt_item ).

    " Summaries - go to the job log in background
    MESSAGE s123 WITH mv_dlv_selected mv_dlv_changed mv_batch_changed
                      mv_dlv_errors.
    MESSAGE s103 WITH mv_selected mv_changed mv_unchanged mv_errors.

    " Online: the changes of the simulation are proposals to post
    IF p_onl = abap_true.
      LOOP AT mt_log ASSIGNING FIELD-SYMBOL(<ls_log>)
           WHERE msgty = 'S' AND gr_only = abap_false.
        <ls_log>-todo = abap_true.
      ENDLOOP.
    ENDIF.

    display_log( ).

  ENDMETHOD.


  METHOD select_items.

    " Split-valuated materials only: header valuation record (BWTAR =
    " space) with a valuation category.
    " Open quantity: a schedule line not fully received; no goods
    " receipt at all - the valuation type is fixed by the first one
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
        AND p~loekz = @space
        AND p~elikz = @space
        AND p~retpo = @space
        AND v~bwtty <> @space
        AND EXISTS ( SELECT ebeln FROM eket AS e
                       WHERE e~ebeln = p~ebeln
                         AND e~ebelp = p~ebelp
                         AND e~menge > e~wemng )
        AND NOT EXISTS ( SELECT ebeln FROM eket AS r
                           WHERE r~ebeln = p~ebeln
                             AND r~ebelp = p~ebelp
                             AND r~wemng > 0 )
      ORDER BY p~ebeln, p~ebelp
      INTO CORRESPONDING FIELDS OF TABLE @rt_item.

    IF p_gr = abap_false.
      RETURN.
    ENDIF.

    " Also items with a goods receipt (net quantity received), partially
    " or fully received, open or delivery completed - listed only
    DATA lt_received TYPE tt_item.
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
        AND p~loekz = @space
        AND p~retpo = @space
        AND v~bwtty <> @space
        AND EXISTS ( SELECT ebeln FROM eket AS e
                       WHERE e~ebeln = p~ebeln
                         AND e~ebelp = p~ebelp
                         AND e~wemng > 0 )
      INTO CORRESPONDING FIELDS OF TABLE @lt_received.

    " Disjoint from the first selection (no goods receipt there)
    LOOP AT lt_received ASSIGNING FIELD-SYMBOL(<ls_received>).
      <ls_received>-gr_only = abap_true.
      INSERT <ls_received> INTO TABLE rt_item.
    ENDLOOP.

  ENDMETHOD.


  METHOD filter_by_delivery.

    TYPES:
      BEGIN OF ty_key,
        ebeln TYPE ebeln,
        ebelp TYPE ebelp,
      END OF ty_key.

    DATA lt_key TYPE SORTED TABLE OF ty_key WITH NON-UNIQUE KEY ebeln ebelp.

    IF ct_item IS INITIAL.
      RETURN.
    ENDIF.

    " Confirmations with a delivery of the range; the whole flow of the
    " PO item stays selected, also its deliveries outside the range
    SELECT ebeln, ebelp
      FROM ekes
      FOR ALL ENTRIES IN @ct_item
      WHERE ebeln =  @ct_item-ebeln
        AND ebelp =  @ct_item-ebelp
        AND vbeln <> @space
        AND vbeln IN @s_vbeln
      INTO CORRESPONDING FIELDS OF TABLE @lt_key.

    LOOP AT ct_item ASSIGNING FIELD-SYMBOL(<ls_item>).
      IF NOT line_exists( lt_key[ ebeln = <ls_item>-ebeln
                                  ebelp = <ls_item>-ebelp ] ).
        DELETE ct_item.
      ENDIF.
    ENDLOOP.

  ENDMETHOD.


  METHOD read_gr_documents.

    " Goods receipts (not reversals) of the items, latest first
    SELECT ebeln, ebelp, gjahr, belnr
      FROM ekbe
      FOR ALL ENTRIES IN @it_item
      WHERE ebeln = @it_item-ebeln
        AND ebelp = @it_item-ebelp
        AND vgabe = '1'
        AND shkzg = 'S'
      INTO TABLE @DATA(lt_ekbe).

    SORT lt_ekbe BY ebeln ebelp gjahr DESCENDING belnr DESCENDING.
    DELETE ADJACENT DUPLICATES FROM lt_ekbe COMPARING ebeln ebelp.

    mt_gr_doc = VALUE #( FOR ls_ekbe IN lt_ekbe
                         ( ebeln = ls_ekbe-ebeln
                           ebelp = ls_ekbe-ebelp
                           mblnr = ls_ekbe-belnr ) ).

  ENDMETHOD.


  METHOD list_received_items.

    " Valuation type still determined - shows whether it would differ
    LOOP AT ct_item INTO DATA(ls_item) WHERE gr_only = abap_true.
      DATA(ls_log) = determine( ls_item ).
      ls_log-gr_only = abap_true.
      IF ls_log-msgty <> 'E'.
        DATA(lv_mblnr) = VALUE mblnr( mt_gr_doc[ ebeln = ls_item-ebeln
                                                 ebelp = ls_item-ebelp
                                               ]-mblnr OPTIONAL ).
        ls_log-msgty = 'W'.
        MESSAGE w130 WITH lv_mblnr INTO ls_log-message.
      ENDIF.
      APPEND ls_log TO mt_log.
    ENDLOOP.

    DELETE ct_item WHERE gr_only = abap_true.

  ENDMETHOD.


  METHOD select_deliveries.

    TYPES:
      BEGIN OF ty_ekes,
        ebeln TYPE ebeln,
        ebelp TYPE ebelp,
        vbeln TYPE vbeln_vl,
        vbelp TYPE posnr_vl,
      END OF ty_ekes,
      BEGIN OF ty_main,
        vbeln TYPE vbeln_vl,
        posnr TYPE posnr_vl,
      END OF ty_main.

    DATA lt_ekes TYPE SORTED TABLE OF ty_ekes
                 WITH NON-UNIQUE KEY ebeln ebelp.
    DATA lt_main TYPE SORTED TABLE OF ty_main
                 WITH NON-UNIQUE KEY vbeln posnr.

    CLEAR et_dlv.

    " Inbound deliveries of the items (confirmations with a delivery)
    SELECT ebeln, ebelp, vbeln, vbelp
      FROM ekes
      FOR ALL ENTRIES IN @ct_item
      WHERE ebeln = @ct_item-ebeln
        AND ebelp = @ct_item-ebelp
        AND vbeln <> @space
      INTO CORRESPONDING FIELDS OF TABLE @lt_ekes.

    " Scenario 2 also if all deliveries already have their goods receipt
    LOOP AT ct_item ASSIGNING FIELD-SYMBOL(<ls_item>).
      <ls_item>-scen = COND #(
        WHEN line_exists( lt_ekes[ ebeln = <ls_item>-ebeln
                                   ebelp = <ls_item>-ebelp ] )
        THEN c_scen-delivery
        ELSE c_scen-po ).
    ENDLOOP.

    IF lt_ekes IS INITIAL.
      RETURN.
    ENDIF.

    " Items without goods receipt; with a batch split, the sub-items
    " (UECHA = main item) carry the batches
    SELECT l~vbeln, l~posnr, l~uecha, l~vgbel, l~vgpos, l~matnr,
           l~werks, l~charg, l~bwtar
      FROM lips AS l
      INNER JOIN likp AS h ON h~vbeln = l~vbeln
      FOR ALL ENTRIES IN @lt_ekes
      WHERE l~vbeln = @lt_ekes-vbeln
        AND ( l~posnr = @lt_ekes-vbelp OR l~uecha = @lt_ekes-vbelp )
        AND h~vbtyp = '7'
        AND l~wbsta <> 'C'
      INTO CORRESPONDING FIELDS OF TABLE @et_dlv.

    " Main items of a batch split are not processed
    lt_main = VALUE #( FOR ls_sub IN et_dlv WHERE ( uecha IS NOT INITIAL )
                       ( vbeln = ls_sub-vbeln posnr = ls_sub-uecha ) ).
    LOOP AT lt_main ASSIGNING FIELD-SYMBOL(<ls_main>).
      DELETE et_dlv WHERE vbeln = <ls_main>-vbeln
                      AND posnr = <ls_main>-posnr.
    ENDLOOP.

    LOOP AT et_dlv ASSIGNING FIELD-SYMBOL(<ls_dlv>).
      <ls_dlv>-ebeln = <ls_dlv>-vgbel.
      <ls_dlv>-ebelp = <ls_dlv>-vgpos.
    ENDLOOP.

    SORT et_dlv BY vbeln posnr.

  ENDMETHOD.


  METHOD read_batches.

    CLEAR mt_batch_buffer.

    LOOP AT it_dlv INTO DATA(ls_dlv) WHERE charg IS NOT INITIAL.
      INSERT VALUE #( matnr = ls_dlv-matnr
                      werks = ls_dlv-werks
                      charg = ls_dlv-charg )
             INTO TABLE mt_batch_buffer.        " duplicates ignored
    ENDLOOP.

    IF mt_batch_buffer IS INITIAL.
      RETURN.
    ENDIF.

    SELECT matnr, werks, charg, bwtar
      FROM mcha
      FOR ALL ENTRIES IN @mt_batch_buffer
      WHERE matnr = @mt_batch_buffer-matnr
        AND werks = @mt_batch_buffer-werks
        AND charg = @mt_batch_buffer-charg
      INTO TABLE @DATA(lt_mcha).

    " Any material document item of the batch in the plant, reversals
    " included (S/4HANA: MSEG is read from MATDOC)
    SELECT matnr, werks, charg
      FROM mseg
      FOR ALL ENTRIES IN @mt_batch_buffer
      WHERE matnr = @mt_batch_buffer-matnr
        AND werks = @mt_batch_buffer-werks
        AND charg = @mt_batch_buffer-charg
      INTO TABLE @DATA(lt_mseg).

    LOOP AT mt_batch_buffer ASSIGNING FIELD-SYMBOL(<ls_buf>).
      READ TABLE lt_mcha INTO DATA(ls_mcha)
           WITH KEY matnr = <ls_buf>-matnr
                    werks = <ls_buf>-werks
                    charg = <ls_buf>-charg.
      IF sy-subrc = 0.
        <ls_buf>-found = abap_true.
        <ls_buf>-bwtar = ls_mcha-bwtar.
      ENDIF.
      <ls_buf>-used = xsdbool(
        line_exists( lt_mseg[ matnr = <ls_buf>-matnr
                              werks = <ls_buf>-werks
                              charg = <ls_buf>-charg ] ) ).
    ENDLOOP.

  ENDMETHOD.


  METHOD set_batch_reference.

    " One valuation type per PO item: the one of its existing batches
    LOOP AT it_dlv INTO DATA(ls_dlv) WHERE charg IS NOT INITIAL.

      READ TABLE mt_batch_buffer INTO DATA(ls_batch)
           WITH TABLE KEY matnr = ls_dlv-matnr
                          werks = ls_dlv-werks
                          charg = ls_dlv-charg.
      " New batch, or batch not found (error 122 in ALIGN_BATCH)
      IF sy-subrc <> 0 OR ls_batch-used = abap_false
      OR ls_batch-found = abap_false.
        CONTINUE.
      ENDIF.

      READ TABLE ct_item ASSIGNING FIELD-SYMBOL(<ls_item>)
           WITH TABLE KEY ebeln = ls_dlv-ebeln
                          ebelp = ls_dlv-ebelp.
      IF sy-subrc <> 0 OR <ls_item>-ref_error IS NOT INITIAL.
        CONTINUE.
      ENDIF.

      IF ls_batch-bwtar IS INITIAL.
        MESSAGE e132 WITH ls_batch-charg INTO <ls_item>-ref_error.
      ELSEIF <ls_item>-bwtar_ref IS INITIAL.
        <ls_item>-bwtar_ref = ls_batch-bwtar.
        <ls_item>-ref_charg = ls_batch-charg.
      ELSEIF <ls_item>-bwtar_ref <> ls_batch-bwtar.
        MESSAGE e133 WITH <ls_item>-ref_charg <ls_item>-bwtar_ref
                          ls_batch-charg ls_batch-bwtar
                INTO <ls_item>-ref_error.
      ENDIF.

    ENDLOOP.

  ENDMETHOD.


  METHOD is_batch_used.

    rv_used = VALUE #( mt_batch_buffer[ matnr = is_dlv-matnr
                                        werks = is_dlv-werks
                                        charg = is_dlv-charg ]-used
                       OPTIONAL ).

  ENDMETHOD.


  METHOD determine.

    rs_log = VALUE #( scen      = is_item-scen
                      object    = c_object-po_item
                      ebeln     = is_item-ebeln
                      ebelp     = is_item-ebelp
                      werks     = is_item-werks
                      matnr     = is_item-matnr
                      mtart     = is_item-mtart
                      bwtar_old = is_item-bwtar
                      source    = c_source-table ).

    rs_log-gjahr = get_fiscal_year( is_item-bukrs ).

    IF is_item-ref_error IS NOT INITIAL.
      rs_log-msgty   = 'E'.
      rs_log-source  = c_source-batch.
      rs_log-message = is_item-ref_error.
      RETURN.
    ENDIF.

    IF is_item-bwtar_ref IS NOT INITIAL.
      " Existing batch: no table lookup, fiscal year for information only
      rs_log-bwtar_new = is_item-bwtar_ref.
      rs_log-source    = c_source-batch.
    ELSE.
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
    ENDIF.

    " Checked also if the PO item is correct: the value goes to the
    " deliveries and batches. Without valuation record GR will fail.
    IF valtype_exists( iv_matnr = is_item-matnr
                       iv_bwkey = is_item-bwkey
                       iv_bwtar = rs_log-bwtar_new ) = abap_false.
      rs_log-msgty = 'E'.
      MESSAGE e106 WITH rs_log-bwtar_new |{ is_item-matnr ALPHA = OUT }|
                        is_item-werks
              INTO rs_log-message.
    ENDIF.

  ENDMETHOD.


  METHOD align_deliveries.

    DATA lt_change TYPE tt_log.

    LOOP AT it_dlv ASSIGNING FIELD-SYMBOL(<ls_dlv>)
         GROUP BY <ls_dlv>-vbeln INTO DATA(lv_vbeln).

      CLEAR lt_change.

      LOOP AT GROUP lv_vbeln ASSIGNING FIELD-SYMBOL(<ls_member>).

        " Deliveries of PO items in error are not processed
        READ TABLE ct_item ASSIGNING FIELD-SYMBOL(<ls_item>)
             WITH TABLE KEY ebeln = <ls_member>-ebeln
                            ebelp = <ls_member>-ebelp.
        IF sy-subrc <> 0 OR <ls_item>-failed = abap_true.
          CONTINUE.
        ENDIF.

        mv_dlv_selected = mv_dlv_selected + 1.

        DATA(ls_log) = VALUE ty_log(
          scen      = COND #( WHEN <ls_member>-charg IS INITIAL
                              THEN c_scen-no_batch
                              WHEN is_batch_used( <ls_member> ) = abap_true
                              THEN c_scen-used
                              ELSE c_scen-batch )
          object    = c_object-delivery
          ebeln     = <ls_item>-ebeln
          ebelp     = <ls_item>-ebelp
          vbeln     = <ls_member>-vbeln
          posnr     = <ls_member>-posnr
          werks     = <ls_member>-werks
          matnr     = <ls_member>-matnr
          charg     = <ls_member>-charg
          mtart     = <ls_item>-mtart
          gjahr     = <ls_item>-gjahr
          bwtar_old = <ls_member>-bwtar
          bwtar_new = <ls_item>-bwtar_new
          source    = <ls_item>-source ).

        " 2.1: the batch master is saved before the delivery; 2.3: kept
        IF <ls_member>-charg IS NOT INITIAL
        AND align_batch( is_dlv  = <ls_member>
                         is_item = <ls_item> ) = abap_false.
          ls_log-msgty = 'E'.
          MESSAGE e124 WITH <ls_member>-charg INTO ls_log-message.
          APPEND ls_log TO mt_log.
          mv_dlv_errors = mv_dlv_errors + 1.
          block_item( EXPORTING iv_vbeln = <ls_member>-vbeln
                                iv_posnr = <ls_member>-posnr
                      CHANGING  cs_item  = <ls_item> ).
          CONTINUE.
        ENDIF.

        IF ls_log-bwtar_old <> ls_log-bwtar_new.
          APPEND ls_log TO lt_change.
        ENDIF.

      ENDLOOP.

      IF lt_change IS NOT INITIAL.
        change_delivery( EXPORTING iv_vbeln  = lv_vbeln
                         CHANGING  ct_change = lt_change ).
        LOOP AT lt_change ASSIGNING FIELD-SYMBOL(<ls_change>)
             WHERE msgty = 'E'.
          READ TABLE ct_item ASSIGNING <ls_item>
               WITH TABLE KEY ebeln = <ls_change>-ebeln
                              ebelp = <ls_change>-ebelp.
          block_item( EXPORTING iv_vbeln = <ls_change>-vbeln
                                iv_posnr = <ls_change>-posnr
                      CHANGING  cs_item  = <ls_item> ).
        ENDLOOP.
        APPEND LINES OF lt_change TO mt_log.
      ENDIF.

    ENDLOOP.

  ENDMETHOD.


  METHOD align_batch.

    " A batch on several delivery items is checked and changed once
    READ TABLE mt_batch_buffer ASSIGNING FIELD-SYMBOL(<ls_buf>)
         WITH TABLE KEY matnr = is_dlv-matnr
                        werks = is_dlv-werks
                        charg = is_dlv-charg.
    IF sy-subrc <> 0.                        " filled by READ_BATCHES
      INSERT VALUE #( matnr = is_dlv-matnr
                      werks = is_dlv-werks
                      charg = is_dlv-charg )
             INTO TABLE mt_batch_buffer ASSIGNING <ls_buf>.
    ELSEIF <ls_buf>-done = abap_true.
      rv_ok = <ls_buf>-ok.
      RETURN.
    ENDIF.

    <ls_buf>-done = abap_true.

    DATA(lv_scen) = COND ty_scen( WHEN <ls_buf>-used = abap_true
                                  THEN c_scen-used
                                  ELSE c_scen-batch ).

    DATA(ls_log) = VALUE ty_log( scen      = lv_scen
                                 object    = c_object-batch
                                 ebeln     = is_item-ebeln
                                 ebelp     = is_item-ebelp
                                 vbeln     = is_dlv-vbeln
                                 posnr     = is_dlv-posnr
                                 werks     = is_dlv-werks
                                 matnr     = is_dlv-matnr
                                 charg     = is_dlv-charg
                                 mtart     = is_item-mtart
                                 gjahr     = is_item-gjahr
                                 bwtar_old = <ls_buf>-bwtar
                                 bwtar_new = is_item-bwtar_new
                                 source    = is_item-source ).

    IF <ls_buf>-found = abap_false.
      ls_log-msgty = 'E'.
      MESSAGE e122 WITH is_dlv-charg |{ is_dlv-matnr ALPHA = OUT }|
                        is_dlv-werks
              INTO ls_log-message.
      APPEND ls_log TO mt_log.
      RETURN.                                " not aligned, buffered
    ENDIF.

    " 2.3: existing batch - never changed, its valuation type is the
    " reference of the PO item (SET_BATCH_REFERENCE), listed for info
    IF <ls_buf>-used = abap_true.
      ls_log-bwtar_new = ls_log-bwtar_old.
      ls_log-source    = c_source-batch.
      ls_log-msgty     = 'I'.
      MESSAGE i134 WITH is_dlv-charg ls_log-bwtar_old INTO ls_log-message.
      APPEND ls_log TO mt_log.
      <ls_buf>-ok = xsdbool( ls_log-bwtar_old = is_item-bwtar_new ).
      rv_ok = <ls_buf>-ok.
      RETURN.
    ENDIF.

    " Same valuation type: batch master unchanged, not logged
    IF ls_log-bwtar_old = ls_log-bwtar_new.
      <ls_buf>-ok = abap_true.
      rv_ok = abap_true.
      RETURN.
    ENDIF.

    IF mv_test = abap_true.
      ls_log-msgty = 'S'.
      MESSAGE s118 WITH ls_log-bwtar_old ls_log-bwtar_new
              INTO ls_log-message.
    ELSE.
      change_batch( CHANGING cs_log = ls_log ).
    ENDIF.

    APPEND ls_log TO mt_log.

    <ls_buf>-ok = xsdbool( ls_log-msgty <> 'E' ).
    rv_ok = <ls_buf>-ok.
    IF rv_ok = abap_true.
      mv_batch_changed = mv_batch_changed + 1.
    ENDIF.

  ENDMETHOD.


  METHOD change_batch.

    DATA ls_attributes  TYPE bapibatchatt.
    DATA ls_attributesx TYPE bapibatchattx.
    DATA lt_return      TYPE STANDARD TABLE OF bapiret2.

    ls_attributes-val_type  = cs_log-bwtar_new.
    ls_attributesx-val_type = abap_true.

    " SAP accepts the change only while the batch has no stock
    CALL FUNCTION 'BAPI_BATCH_CHANGE'
      EXPORTING
        material_long    = cs_log-matnr
        batch            = cs_log-charg
        plant            = cs_log-werks
        batchattributes  = ls_attributes
        batchattributesx = ls_attributesx
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

    " Committed before the delivery is changed
    CALL FUNCTION 'BAPI_TRANSACTION_COMMIT'
      EXPORTING
        wait = abap_true.

    " Batch master read back - the delivery needs the new value
    SELECT SINGLE bwtar
      FROM mcha
      WHERE matnr = @cs_log-matnr
        AND werks = @cs_log-werks
        AND charg = @cs_log-charg
      INTO @DATA(lv_bwtar).
    IF lv_bwtar <> cs_log-bwtar_new.
      cs_log-msgty = 'E'.
      MESSAGE e129 WITH cs_log-bwtar_new lv_bwtar INTO cs_log-message.
      RETURN.
    ENDIF.

    cs_log-msgty    = 'S'.
    cs_log-verified = abap_true.
    MESSAGE s117 WITH cs_log-bwtar_old cs_log-bwtar_new
            INTO cs_log-message.

  ENDMETHOD.


  METHOD change_delivery.

    DATA ls_vbkok TYPE vbkok.
    DATA lt_vbpok TYPE STANDARD TABLE OF vbpok.
    DATA lt_prot  TYPE STANDARD TABLE OF prott.
    DATA lv_error TYPE abap_bool.
    DATA lv_text  TYPE bapi_msg.

    IF mv_test = abap_true.
      LOOP AT ct_change ASSIGNING FIELD-SYMBOL(<ls_change>).
        <ls_change>-msgty = 'S'.
        MESSAGE s120 WITH <ls_change>-bwtar_old <ls_change>-bwtar_new
                INTO <ls_change>-message.
      ENDLOOP.
      mv_dlv_changed = mv_dlv_changed + lines( ct_change ).
      RETURN.
    ENDIF.

    ls_vbkok-vbeln_vl = iv_vbeln.
    ls_vbkok-vbtyp_vl = '7'.

    " Batch passed again so that it is kept; quantities are not passed
    lt_vbpok = VALUE #( FOR ls_c IN ct_change
                        ( vbeln_vl = iv_vbeln
                          posnr_vl = ls_c-posnr
                          vbeln    = iv_vbeln
                          posnn    = ls_c-posnr
                          matnr    = ls_c-matnr
                          charg    = ls_c-charg
                          bwtar    = ls_c-bwtar_new ) ).

    CALL FUNCTION 'WS_DELIVERY_UPDATE_2'
      EXPORTING
        vbkok_wa                 = ls_vbkok
        synchron                 = abap_true
        commit                   = abap_true
        delivery                 = iv_vbeln
      IMPORTING
        ef_error_any             = lv_error
      TABLES
        vbpok_tab                = lt_vbpok
        prot                     = lt_prot
      EXCEPTIONS
        error_message            = 1
        OTHERS                   = 2.

    IF sy-subrc <> 0.
      lv_error = abap_true.
      MESSAGE ID sy-msgid TYPE 'E' NUMBER sy-msgno
              WITH sy-msgv1 sy-msgv2 sy-msgv3 sy-msgv4
              INTO lv_text.
    ELSEIF lv_error = abap_true.
      LOOP AT lt_prot INTO DATA(ls_prot)
           WHERE msgty = 'E' OR msgty = 'A'.
        MESSAGE ID ls_prot-msgid TYPE 'E' NUMBER ls_prot-msgno
                WITH ls_prot-msgv1 ls_prot-msgv2
                     ls_prot-msgv3 ls_prot-msgv4
                INTO lv_text.
        EXIT.
      ENDLOOP.
      IF lv_text IS INITIAL.
        MESSAGE e125 WITH iv_vbeln INTO lv_text.
      ENDIF.
    ENDIF.

    " Next delivery is read fresh from the database
    CALL FUNCTION 'LE_DELIVERY_REFRESH_BUFFER'
      EXCEPTIONS
        OTHERS = 1.

    " Treated like the PO: all items of the delivery or none
    IF lv_error = abap_true.
      CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
      LOOP AT ct_change ASSIGNING <ls_change>.
        <ls_change>-msgty   = 'E'.
        <ls_change>-message = lv_text.
      ENDLOOP.
      mv_dlv_errors = mv_dlv_errors + lines( ct_change ).
      RETURN.
    ENDIF.

    " Delivery items read back - already committed, so a missing value
    " is an error of this item only
    SELECT posnr, bwtar
      FROM lips
      WHERE vbeln = @iv_vbeln
      INTO TABLE @DATA(lt_lips).

    LOOP AT ct_change ASSIGNING <ls_change>.
      DATA(lv_bwtar) = VALUE bwtar_d(
                         lt_lips[ posnr = <ls_change>-posnr ]-bwtar OPTIONAL ).
      IF lv_bwtar <> <ls_change>-bwtar_new.
        <ls_change>-msgty = 'E'.
        MESSAGE e129 WITH <ls_change>-bwtar_new lv_bwtar
                INTO <ls_change>-message.
        mv_dlv_errors = mv_dlv_errors + 1.
        CONTINUE.
      ENDIF.
      <ls_change>-msgty    = 'S'.
      <ls_change>-verified = abap_true.
      MESSAGE s119 WITH <ls_change>-bwtar_old <ls_change>-bwtar_new
              INTO <ls_change>-message.
      mv_dlv_changed = mv_dlv_changed + 1.
    ENDLOOP.

  ENDMETHOD.


  METHOD block_item.

    IF cs_item-blocked_vbeln IS INITIAL.
      cs_item-blocked_vbeln = iv_vbeln.
      cs_item-blocked_posnr = iv_posnr.
    ENDIF.

  ENDMETHOD.


  METHOD list_unchanged.

    DATA lt_add TYPE tt_log.

    " Items in error (D2): deliveries not processed, target unknown
    LOOP AT it_item INTO DATA(ls_item) WHERE failed = abap_false.

      " Only flows with at least one listed object; P_ALIGN: all flows
      IF p_align = abap_false
      AND NOT line_exists( mt_log[ ebeln = ls_item-ebeln
                                   ebelp = ls_item-ebelp ] ).
        CONTINUE.
      ENDIF.

      DATA(ls_base) = VALUE ty_log( msgty    = 'I'
                                    nochange = abap_true
                                    ebeln    = ls_item-ebeln
                                    ebelp    = ls_item-ebelp
                                    werks    = ls_item-werks
                                    matnr    = ls_item-matnr
                                    mtart    = ls_item-mtart
                                    gjahr    = ls_item-gjahr
                                    source   = ls_item-source ).

      " PO item counted as already correct (103), not logged
      IF NOT line_exists( mt_log[ object = c_object-po_item
                                  ebeln  = ls_item-ebeln
                                  ebelp  = ls_item-ebelp ] )
      AND ls_item-bwtar = ls_item-bwtar_new.
        DATA(ls_add) = ls_base.
        ls_add-scen      = ls_item-scen.
        ls_add-object    = c_object-po_item.
        ls_add-bwtar_old = ls_item-bwtar.
        ls_add-bwtar_new = ls_item-bwtar.
        MESSAGE i136 WITH ls_add-bwtar_old INTO ls_add-message.
        APPEND ls_add TO lt_add.
      ENDIF.

      LOOP AT it_dlv INTO DATA(ls_dlv) WHERE ebeln = ls_item-ebeln
                                         AND ebelp = ls_item-ebelp.

        DATA(lv_scen) = COND ty_scen(
          WHEN ls_dlv-charg IS INITIAL
          THEN c_scen-no_batch
          WHEN is_batch_used( ls_dlv ) = abap_true
          THEN c_scen-used
          ELSE c_scen-batch ).

        " Batch: once, and not if listed in another flow (shared batch)
        IF ls_dlv-charg IS NOT INITIAL
        AND NOT line_exists( mt_log[ object = c_object-batch
                                     matnr  = ls_dlv-matnr
                                     werks  = ls_dlv-werks
                                     charg  = ls_dlv-charg ] )
        AND NOT line_exists( lt_add[ object = c_object-batch
                                     matnr  = ls_dlv-matnr
                                     werks  = ls_dlv-werks
                                     charg  = ls_dlv-charg ] ).
          DATA(lv_bwtar) = VALUE bwtar_d(
                             mt_batch_buffer[ matnr = ls_dlv-matnr
                                              werks = ls_dlv-werks
                                              charg = ls_dlv-charg ]-bwtar
                             OPTIONAL ).
          IF lv_bwtar = ls_item-bwtar_new.
            ls_add = ls_base.
            ls_add-scen      = lv_scen.
            ls_add-object    = c_object-batch.
            ls_add-vbeln     = ls_dlv-vbeln.
            ls_add-posnr     = ls_dlv-posnr.
            ls_add-werks     = ls_dlv-werks.
            ls_add-matnr     = ls_dlv-matnr.
            ls_add-charg     = ls_dlv-charg.
            ls_add-bwtar_old = lv_bwtar.
            ls_add-bwtar_new = lv_bwtar.
            MESSAGE i136 WITH lv_bwtar INTO ls_add-message.
            APPEND ls_add TO lt_add.
          ENDIF.
        ENDIF.

        IF NOT line_exists( mt_log[ object = c_object-delivery
                                    vbeln  = ls_dlv-vbeln
                                    posnr  = ls_dlv-posnr ] )
        AND ls_dlv-bwtar = ls_item-bwtar_new.
          ls_add = ls_base.
          ls_add-scen      = lv_scen.
          ls_add-object    = c_object-delivery.
          ls_add-vbeln     = ls_dlv-vbeln.
          ls_add-posnr     = ls_dlv-posnr.
          ls_add-werks     = ls_dlv-werks.
          ls_add-matnr     = ls_dlv-matnr.
          ls_add-charg     = ls_dlv-charg.
          ls_add-bwtar_old = ls_dlv-bwtar.
          ls_add-bwtar_new = ls_dlv-bwtar.
          MESSAGE i136 WITH ls_dlv-bwtar INTO ls_add-message.
          APPEND ls_add TO lt_add.
        ENDIF.

      ENDLOOP.

    ENDLOOP.

    APPEND LINES OF lt_add TO mt_log.

  ENDMETHOD.


  METHOD update_purchase_orders.

    DATA lt_change TYPE tt_log.

    LOOP AT it_item ASSIGNING FIELD-SYMBOL(<ls_item>)
         GROUP BY <ls_item>-ebeln INTO DATA(lv_ebeln).

      CLEAR lt_change.

      LOOP AT GROUP lv_ebeln ASSIGNING FIELD-SYMBOL(<ls_member>).

        IF <ls_member>-failed = abap_true.
          CONTINUE.                       " already logged by DETERMINE
        ENDIF.

        DATA(ls_log) = VALUE ty_log( scen      = <ls_member>-scen
                                     object    = c_object-po_item
                                     ebeln     = <ls_member>-ebeln
                                     ebelp     = <ls_member>-ebelp
                                     werks     = <ls_member>-werks
                                     matnr     = <ls_member>-matnr
                                     mtart     = <ls_member>-mtart
                                     gjahr     = <ls_member>-gjahr
                                     bwtar_old = <ls_member>-bwtar
                                     bwtar_new = <ls_member>-bwtar_new
                                     source    = <ls_member>-source ).

        IF <ls_member>-blocked_vbeln IS NOT INITIAL.
          ls_log-msgty = 'E'.
          ls_log-vbeln = <ls_member>-blocked_vbeln.
          ls_log-posnr = <ls_member>-blocked_posnr.
          MESSAGE e121 WITH <ls_member>-blocked_vbeln
                            <ls_member>-blocked_posnr
                  INTO ls_log-message.
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
        testrun       = mv_test
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

    IF mv_test = abap_true.
      CALL FUNCTION 'BAPI_TRANSACTION_ROLLBACK'.
      LOOP AT ct_change ASSIGNING <ls_change>.
        <ls_change>-msgty = 'S'.
        MESSAGE s102 WITH <ls_change>-bwtar_old <ls_change>-bwtar_new
                INTO <ls_change>-message.
      ENDLOOP.
      mv_changed = mv_changed + lines( ct_change ).
      RETURN.
    ENDIF.

    CALL FUNCTION 'BAPI_TRANSACTION_COMMIT'
      EXPORTING
        wait = abap_true.

    " PO items read back - already committed, so a missing value is an
    " error of this item only
    SELECT ebelp, bwtar
      FROM ekpo
      WHERE ebeln = @iv_ebeln
      INTO TABLE @DATA(lt_ekpo).

    LOOP AT ct_change ASSIGNING <ls_change>.
      DATA(lv_bwtar) = VALUE bwtar_d(
                         lt_ekpo[ ebelp = <ls_change>-ebelp ]-bwtar OPTIONAL ).
      IF lv_bwtar <> <ls_change>-bwtar_new.
        <ls_change>-msgty = 'E'.
        MESSAGE e129 WITH <ls_change>-bwtar_new lv_bwtar
                INTO <ls_change>-message.
        mv_errors = mv_errors + 1.
        CONTINUE.
      ENDIF.
      <ls_change>-msgty    = 'S'.
      <ls_change>-verified = abap_true.
      MESSAGE s101 WITH <ls_change>-bwtar_old <ls_change>-bwtar_new
              INTO <ls_change>-message.
      mv_changed = mv_changed + 1.
    ENDLOOP.

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

    " Only changes (or changes of the test run) and errors are listed;
    " in background the list goes to the spool of the job
    IF mt_log IS INITIAL.
      RETURN.
    ENDIF.

    build_output( ).

    TRY.
        cl_salv_table=>factory( IMPORTING r_salv_table = mo_alv
                                CHANGING  t_table      = mt_out ).

        IF p_onl = abap_true.
          " Own status for function POST; rows selectable
          mo_alv->set_screen_status(
            report        = sy-repid
            pfstatus      = c_status
            set_functions = cl_salv_table=>c_functions_all ).
          mo_alv->get_selections( )->set_selection_mode(
            if_salv_c_selection_mode=>row_column ).
          SET HANDLER on_added_function FOR mo_alv->get_event( ).
        ELSE.
          mo_alv->get_functions( )->set_all( abap_true ).
        ENDIF.

        DATA(lo_columns) = mo_alv->get_columns( ).
        lo_columns->set_optimize( abap_true ).
        lo_columns->set_color_column( 'T_COLOR' ).
        " Traffic light from the message type
        lo_columns->set_exception_column( 'LIGHT' ).
        set_column_text( io_columns = lo_columns
                         iv_name    = 'LIGHT'
                         iv_short   = 'Status'(t33)
                         iv_medium  = 'Status'(t34) ).
        set_column_text( io_columns = lo_columns
                         iv_name    = 'POSTED'
                         iv_short   = 'Posted'(t29)
                         iv_medium  = 'Posted'(t30) ).
        DATA(lo_posted) = CAST cl_salv_column_table(
                            lo_columns->get_column( 'POSTED' ) ).
        lo_posted->set_cell_type( if_salv_c_cell_type=>checkbox ).
        lo_posted->set_visible( p_onl ).
        lo_columns->get_column( 'LOGIDX' )->set_technical( abap_true ).
        lo_columns->get_column( 'MBLNR' )->set_visible( p_gr ).

        " Grouped by PO (repeated PO numbers suppressed, line after each
        " PO), ascending; within the PO by the hidden SEQ - not by EBELP,
        " as the ALV would also suppress repeated item numbers
        lo_columns->get_column( 'SEQ' )->set_visible( abap_false ).
        lo_columns->get_column( 'RANK' )->set_technical( abap_true ).
        DATA(lo_sorts) = mo_alv->get_sorts( ).
        lo_sorts->add_sort( columnname = 'EBELN'
                            sequence   = if_salv_c_sort=>sort_up
                            group      = if_salv_c_sort=>group_with_underline ).
        lo_sorts->add_sort( columnname = 'SEQ'
                            sequence   = if_salv_c_sort=>sort_up ).
        " Own titles - both item numbers are called "Item" by default
        set_column_text( io_columns = lo_columns
                         iv_name    = 'EBELP'
                         iv_short   = 'PO item'(t35)
                         iv_medium  = 'PO item'(t36)
                         iv_long    = 'Purchase order item'(t37) ).
        set_column_text( io_columns = lo_columns
                         iv_name    = 'POSNR'
                         iv_short   = 'Dlv item'(t38)
                         iv_medium  = 'Delivery item'(t39)
                         iv_long    = 'Delivery note item'(t40) ).
        set_column_text( io_columns = lo_columns
                         iv_name    = 'BAT_USED'
                         iv_short   = 'Bat moved'(t44)
                         iv_medium  = 'Batch with movement'(t45)
                         iv_long    = 'Batch with material movement'(t46) ).
        DATA(lo_bat_used) = CAST cl_salv_column_table(
                              lo_columns->get_column( 'BAT_USED' ) ).
        lo_bat_used->set_cell_type( if_salv_c_cell_type=>checkbox ).
        set_column_text( io_columns = lo_columns
                         iv_name    = 'SOURCE'
                         iv_short   = 'Reference'(t41)
                         iv_medium  = 'VType reference'(t42)
                         iv_long    = 'Valuation type reference'(t43) ).
        set_column_text( io_columns = lo_columns
                         iv_name    = 'SCEN'
                         iv_short   = 'Scenario'(t05)
                         iv_medium  = 'Scenario'(t06) ).
        set_column_text( io_columns = lo_columns
                         iv_name    = 'OBJECT'
                         iv_short   = 'Object'(t07)
                         iv_medium  = 'Changed object'(t08) ).
        set_column_text(
          io_columns = lo_columns
          iv_name    = 'PO_BWTAR_OLD'
          iv_short   = 'PO VT old'(t11)
          iv_medium  = 'PO VType (old)'(t12)
          iv_long    = 'Purchase order valuation type (old)'(t13) ).
        set_column_text(
          io_columns = lo_columns
          iv_name    = 'PO_BWTAR_NEW'
          iv_short   = 'PO VT new'(t14)
          iv_medium  = 'PO VType (new)'(t15)
          iv_long    = 'Purchase order valuation type (new)'(t16) ).
        set_column_text(
          io_columns = lo_columns
          iv_name    = 'DLV_BWTAR_OLD'
          iv_short   = 'Dlv VT old'(t17)
          iv_medium  = 'Delivery VType (old)'(t18)
          iv_long    = 'Delivery note valuation type (old)'(t19) ).
        set_column_text(
          io_columns = lo_columns
          iv_name    = 'DLV_BWTAR_NEW'
          iv_short   = 'Dlv VT new'(t20)
          iv_medium  = 'Delivery VType (new)'(t21)
          iv_long    = 'Delivery note valuation type (new)'(t22) ).
        set_column_text(
          io_columns = lo_columns
          iv_name    = 'BAT_BWTAR_OLD'
          iv_short   = 'Bat VT old'(t23)
          iv_medium  = 'Batch VType (old)'(t24)
          iv_long    = 'Batch valuation type (old)'(t25) ).
        set_column_text(
          io_columns = lo_columns
          iv_name    = 'BAT_BWTAR_NEW'
          iv_short   = 'Bat VT new'(t26)
          iv_medium  = 'Batch VType (new)'(t27)
          iv_long    = 'Batch valuation type (new)'(t28) ).

        mo_alv->display( ).

      CATCH cx_salv_msg cx_salv_not_found cx_salv_data_error
            cx_salv_existing INTO DATA(lx_salv).
        MESSAGE lx_salv TYPE 'I'.
    ENDTRY.

  ENDMETHOD.


  METHOD build_output.

    DATA lv_new_column TYPE lvc_fname.

    " The ALV sorts MT_OUT - each line keeps its MT_LOG line in LOGIDX
    CLEAR mt_out.

    LOOP AT mt_log INTO DATA(ls_log).
      DATA(lv_logidx) = sy-tabix.
      DATA(ls_out) = CORRESPONDING ty_out( ls_log ).
      ls_out-logidx = lv_logidx.
      ls_out-mblnr  = VALUE #( mt_gr_doc[ ebeln = ls_log-ebeln
                                          ebelp = ls_log-ebelp ]-mblnr
                               OPTIONAL ).
      ls_out-light  = COND #( WHEN ls_log-msgty = 'E' OR ls_log-msgty = 'A'
                              THEN '1'
                              WHEN ls_log-msgty = 'W'
                              THEN '2'
                              WHEN ls_log-msgty = 'S'
                              THEN '3' ).
      " Information only (existing batch 134, already correct 136): no
      " light - nothing done, nothing to post
      CASE ls_log-object.
        WHEN c_object-po_item.
          ls_out-po_bwtar_old  = ls_log-bwtar_old.
          ls_out-po_bwtar_new  = ls_log-bwtar_new.
          lv_new_column        = 'PO_BWTAR_NEW'.
        WHEN c_object-delivery.
          ls_out-dlv_bwtar_old = ls_log-bwtar_old.
          ls_out-dlv_bwtar_new = ls_log-bwtar_new.
          lv_new_column        = 'DLV_BWTAR_NEW'.
        WHEN c_object-batch.
          ls_out-bat_bwtar_old = ls_log-bwtar_old.
          ls_out-bat_bwtar_new = ls_log-bwtar_new.
          ls_out-bat_used      = VALUE #( mt_batch_buffer[
                                            matnr = ls_log-matnr
                                            werks = ls_log-werks
                                            charg = ls_log-charg ]-used
                                          OPTIONAL ).
          lv_new_column        = 'BAT_BWTAR_NEW'.
      ENDCASE.
      " Existing batch kept as reference - batch old / new orange
      " Change confirmed on the database (background or posted online) -
      " green; test run / online proposal (would be changed) - yellow,
      " orange if the value comes from an existing batch
      IF ls_log-object = c_object-batch AND ls_log-msgty = 'I'
      AND ls_log-nochange = abap_false.
        ls_out-t_color = VALUE #( ( fname = 'BAT_BWTAR_OLD'
                                    color-col = col_group )
                                  ( fname = 'BAT_BWTAR_NEW'
                                    color-col = col_group ) ).
      ELSEIF ls_log-verified = abap_true.
        ls_out-t_color = VALUE #( ( fname = lv_new_column
                                    color-col = col_positive ) ).
      ELSEIF ls_log-msgty = 'S'.
        ls_out-t_color = VALUE #( ( fname = lv_new_column
                                    color-col = COND #(
                                      WHEN ls_log-source = c_source-batch
                                      THEN col_group
                                      ELSE col_total ) ) ).
      ENDIF.
      APPEND ls_out TO mt_out.
    ENDLOOP.

    " Processing order within the PO: batches, deliveries, PO items -
    " each by item. SEQ keeps it when the ALV sorts by PO.
    LOOP AT mt_out ASSIGNING FIELD-SYMBOL(<ls_rank>).
      <ls_rank>-rank = SWITCH #( <ls_rank>-object
                                 WHEN c_object-batch    THEN 1
                                 WHEN c_object-delivery THEN 2
                                 ELSE 3 ).
    ENDLOOP.
    SORT mt_out STABLE BY ebeln rank ebelp.
    LOOP AT mt_out ASSIGNING FIELD-SYMBOL(<ls_out>).
      <ls_out>-seq = sy-tabix.
    ENDLOOP.

  ENDMETHOD.


  METHOD on_added_function.

    IF e_salv_function <> c_fcode_post.
      RETURN.
    ENDIF.

    DATA(lo_selections) = mo_alv->get_selections( ).
    DATA(lt_rows) = lo_selections->get_selected_rows( ).

    " SALV cannot disable single rows: lines of an existing batch (never
    " changed) are removed from the selection and shown deselected
    DATA(lv_count) = lines( lt_rows ).
    LOOP AT lt_rows INTO DATA(lv_sel).
      IF  mt_out[ lv_sel ]-object   = c_object-batch
      AND mt_out[ lv_sel ]-bat_used = abap_true.
        DELETE lt_rows.
      ENDIF.
    ENDLOOP.
    IF lines( lt_rows ) <> lv_count.
      lo_selections->set_selected_rows( lt_rows ).
    ENDIF.

    " Selected ALV rows -> lines of MT_LOG
    post_selected( VALUE #( FOR lv_row IN lt_rows
                            ( mt_out[ lv_row ]-logidx ) ) ).

    build_output( ).
    mo_alv->refresh( ).

  ENDMETHOD.


  METHOD post_selected.

    DATA lt_post     TYPE tt_log.
    DATA lv_answer   TYPE c LENGTH 1.
    DATA lv_received TYPE i.

    " SALV cannot lock single rows: a selection with an item with goods
    " receipt is refused as a whole, nothing is posted
    LOOP AT it_rows INTO DATA(lv_row).
      READ TABLE mt_log INDEX lv_row INTO DATA(ls_log).
      IF sy-subrc = 0 AND ls_log-gr_only = abap_true.
        lv_received = lv_received + 1.
      ENDIF.
    ENDLOOP.
    IF lv_received > 0.
      MESSAGE s131 WITH lv_received DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.

    " Only proposals not posted yet (also failed postings, for a retry);
    " errors of the simulation cannot be posted
    LOOP AT it_rows INTO lv_row.
      READ TABLE mt_log INDEX lv_row INTO ls_log.
      IF sy-subrc = 0 AND ls_log-todo = abap_true.
        ls_log-logidx = lv_row.
        APPEND ls_log TO lt_post.
      ENDIF.
    ENDLOOP.

    IF lt_post IS INITIAL.
      MESSAGE s127 DISPLAY LIKE 'E'.
      RETURN.
    ENDIF.

    CALL FUNCTION 'POPUP_TO_CONFIRM'
      EXPORTING
        titlebar              = 'Post changes'(t31)
        text_question         = 'Post the selected changes?'(t32)
        display_cancel_button = abap_false
      IMPORTING
        answer                = lv_answer
      EXCEPTIONS
        OTHERS                = 1.
    IF sy-subrc <> 0 OR lv_answer <> '1'.
      RETURN.
    ENDIF.

    mv_test = abap_false.

    " Same order as in background mode
    post_batches( CHANGING ct_post = lt_post ).
    post_deliveries( CHANGING ct_post = lt_post ).
    post_purchase_orders( CHANGING ct_post = lt_post ).

    DATA(lv_posted) = 0.
    LOOP AT lt_post ASSIGNING FIELD-SYMBOL(<ls_post>).
      IF <ls_post>-msgty <> 'E'.
        <ls_post>-todo   = abap_false.
        <ls_post>-posted = abap_true.
        lv_posted = lv_posted + 1.
      ENDIF.
      MODIFY mt_log INDEX <ls_post>-logidx FROM <ls_post>.
    ENDLOOP.

    DATA(lv_failed) = lines( lt_post ) - lv_posted.
    MESSAGE s128 WITH lv_posted lv_failed.

  ENDMETHOD.


  METHOD post_batches.

    LOOP AT ct_post ASSIGNING FIELD-SYMBOL(<ls_post>)
         WHERE object = c_object-batch.
      change_batch( CHANGING cs_log = <ls_post> ).
    ENDLOOP.

  ENDMETHOD.


  METHOD post_deliveries.

    DATA lt_change TYPE tt_log.
    DATA lv_bwtar  TYPE bwtar_d.

    LOOP AT ct_post ASSIGNING FIELD-SYMBOL(<ls_post>)
         WHERE object = c_object-delivery
         GROUP BY <ls_post>-vbeln INTO DATA(lv_vbeln).

      CLEAR lt_change.

      LOOP AT GROUP lv_vbeln ASSIGNING FIELD-SYMBOL(<ls_member>).
        " 2.1: batch master read again - may have been posted just now
        IF <ls_member>-charg IS NOT INITIAL.
          CLEAR lv_bwtar.
          SELECT SINGLE bwtar
            FROM mcha
            WHERE matnr = @<ls_member>-matnr
              AND werks = @<ls_member>-werks
              AND charg = @<ls_member>-charg
            INTO @lv_bwtar.
          IF lv_bwtar <> <ls_member>-bwtar_new.
            <ls_member>-msgty = 'E'.
            MESSAGE e124 WITH <ls_member>-charg INTO <ls_member>-message.
            CONTINUE.
          ENDIF.
        ENDIF.
        APPEND <ls_member> TO lt_change.
      ENDLOOP.

      IF lt_change IS NOT INITIAL.
        change_delivery( EXPORTING iv_vbeln  = lv_vbeln
                         CHANGING  ct_change = lt_change ).
        LOOP AT lt_change INTO DATA(ls_change).
          ct_post[ logidx = ls_change-logidx ] = ls_change.
        ENDLOOP.
      ENDIF.

    ENDLOOP.

  ENDMETHOD.


  METHOD post_purchase_orders.

    DATA lt_item   TYPE tt_item.
    DATA lt_dlv    TYPE tt_dlv.
    DATA lt_change TYPE tt_log.

    " Open delivery items read again - may have been posted just now
    LOOP AT ct_post INTO DATA(ls_post)
         WHERE object = c_object-po_item
           AND scen   = c_scen-delivery.
      INSERT VALUE #( ebeln = ls_post-ebeln ebelp = ls_post-ebelp )
             INTO TABLE lt_item.
    ENDLOOP.
    IF lt_item IS NOT INITIAL.
      select_deliveries( IMPORTING et_dlv  = lt_dlv
                         CHANGING  ct_item = lt_item ).
    ENDIF.

    LOOP AT ct_post ASSIGNING FIELD-SYMBOL(<ls_post>)
         WHERE object = c_object-po_item
         GROUP BY <ls_post>-ebeln INTO DATA(lv_ebeln).

      CLEAR lt_change.

      LOOP AT GROUP lv_ebeln ASSIGNING FIELD-SYMBOL(<ls_member>).
        LOOP AT lt_dlv INTO DATA(ls_dlv)
             WHERE ebeln =  <ls_member>-ebeln
               AND ebelp =  <ls_member>-ebelp
               AND bwtar <> <ls_member>-bwtar_new.
          EXIT.
        ENDLOOP.
        IF sy-subrc = 0.
          <ls_member>-msgty = 'E'.
          <ls_member>-vbeln = ls_dlv-vbeln.
          <ls_member>-posnr = ls_dlv-posnr.
          MESSAGE e121 WITH ls_dlv-vbeln ls_dlv-posnr
                  INTO <ls_member>-message.
          CONTINUE.
        ENDIF.
        CLEAR: <ls_member>-vbeln, <ls_member>-posnr.
        APPEND <ls_member> TO lt_change.
      ENDLOOP.

      IF lt_change IS NOT INITIAL.
        change_po( EXPORTING iv_ebeln  = lv_ebeln
                   CHANGING  ct_change = lt_change ).
        LOOP AT lt_change INTO DATA(ls_change).
          ct_post[ logidx = ls_change-logidx ] = ls_change.
        ENDLOOP.
      ENDIF.

    ENDLOOP.

  ENDMETHOD.


  METHOD set_column_text.

    DATA(lo_column) = io_columns->get_column( iv_name ).
    lo_column->set_short_text( CONV #( iv_short ) ).
    lo_column->set_medium_text( CONV #( iv_medium ) ).
    lo_column->set_long_text( CONV #( COND string( WHEN iv_long IS INITIAL
                                                   THEN iv_medium
                                                   ELSE iv_long ) ) ).

  ENDMETHOD.

ENDCLASS.


AT SELECTION-SCREEN OUTPUT.
  " Test run only in background mode - the online proposal is always
  " simulated, postings from the ALV are always real
  LOOP AT SCREEN.
    IF screen-group1 = 'TST' AND p_onl = abap_true.
      screen-input = 0.
      MODIFY SCREEN.
    ENDIF.
  ENDLOOP.

AT SELECTION-SCREEN.
  IF sy-ucomm = 'SJOB' AND p_onl = abap_true.
    MESSAGE e126.
  ENDIF.

START-OF-SELECTION.
  NEW lcl_app( )->run( ).
