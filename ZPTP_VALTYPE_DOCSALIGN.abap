*---------------------------------------------------------------------*
* Report ZPTP_VALTYPE_DOCSALIGN
* Aligns the valuation type (BWTAR) of open purchase order items, of
* their open inbound deliveries and of the batches on these deliveries
* with table ZPTP_301_VALTYPE. Extends report ZPTP_PO_SPLIT_VAL_UPDATE.
* Valuation type from ZPTP_301_VALTYPE, same lookup order as
* ZPTP_PO_SPLIT_VAL_UPDATE (plant + material type, plant, material
* type, global default; only ACTIVE entries). Year = fiscal year of the
* run date (SY-DATLO) in the item's company code.
* Open item = standard PO (BSTYP F), PO and item not deleted, not
* delivery completed, no return item, quantity still to be received on
* a schedule line (EKET-MENGE > EKET-WEMNG). Only split-valuated
* materials; the new valuation type must have its own valuation record
* (MBEW, not flagged for deletion).
* Scenario 1 - item without inbound delivery: PO item updated as in
*   ZPTP_PO_SPLIT_VAL_UPDATE.
* Scenario 2 - item with inbound deliveries (EKES-VBELN). Only delivery
*   items without goods receipt (LIPS-WBSTA <> C) are processed:
*   2.1 with batch: the batch master (MCHA-BWTAR) is changed first if
*       it differs (BAPI_BATCH_CHANGE), then the delivery item;
*   2.2 without batch: the delivery item only.
*   Delivery item (LIPS-BWTAR) changed with WS_DELIVERY_UPDATE_2, one
*   call per delivery. Then the PO item, only if all its open delivery
*   items are aligned - so it gets the valuation type of its deliveries.
* PO items: BAPI_PO_CHANGE, one call per PO, without output
* determination (NO_MESSAGING).
* Test run: no batch or delivery change; BAPI_PO_CHANGE with TESTRUN.
* S/4HANA: goods movement status in LIPS-WBSTA (ECC: VBUP-WBSTA).
* Messages: class ZPTP_SPLIT_VAL, 100 - 104, 106, 107, 117 - 125.
*---------------------------------------------------------------------*
REPORT zptp_valtype_docsalign MESSAGE-ID zptp_split_val.

TABLES ekpo.

SELECT-OPTIONS: s_werks FOR ekpo-werks DEFAULT '8Q01',
                s_ebeln FOR ekpo-ebeln.

PARAMETERS p_test AS CHECKBOX DEFAULT abap_true.


CLASS lcl_app DEFINITION FINAL.

  PUBLIC SECTION.
    METHODS run.

  PRIVATE SECTION.

    TYPES:
      ty_scen   TYPE c LENGTH 3,
      ty_object TYPE c LENGTH 10,

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
                     WITH UNIQUE KEY matnr bwkey bwtar,

      BEGIN OF ty_batch_buffer,
        matnr TYPE matnr,
        werks TYPE werks_d,
        charg TYPE charg_d,
        ok    TYPE abap_bool,
      END OF ty_batch_buffer,
      tt_batch_buffer TYPE HASHED TABLE OF ty_batch_buffer
                      WITH UNIQUE KEY matnr werks charg.

    CONSTANTS:
      BEGIN OF c_scen,
        po       TYPE ty_scen VALUE '1',
        delivery TYPE ty_scen VALUE '2',
        batch    TYPE ty_scen VALUE '2.1',
        no_batch TYPE ty_scen VALUE '2.2',
      END OF c_scen,
      BEGIN OF c_object,
        po_item  TYPE ty_object VALUE 'PO ITEM',
        delivery TYPE ty_object VALUE 'DELIVERY',
        batch    TYPE ty_object VALUE 'BATCH',
      END OF c_object.

    "! Run date - base of the fiscal year
    DATA mv_date TYPE d.

    DATA mt_log            TYPE tt_log.
    DATA mt_year_buffer    TYPE tt_year_buffer.
    DATA mt_valtype_buffer TYPE tt_valtype_buffer.
    DATA mt_mbew_buffer    TYPE tt_mbew_buffer.
    DATA mt_batch_buffer   TYPE tt_batch_buffer.

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

    METHODS select_items
      RETURNING VALUE(rt_item) TYPE tt_item.

    "! Open inbound delivery items of the PO items; sets the scenario
    METHODS select_deliveries
      EXPORTING et_dlv  TYPE tt_dlv
      CHANGING  ct_item TYPE tt_item.

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

    METHODS set_column_text
      IMPORTING io_columns TYPE REF TO cl_salv_columns_table
                iv_name    TYPE lvc_fname
                iv_short   TYPE csequence    " text symbols of any
                iv_medium  TYPE csequence    " maximum length
      RAISING   cx_salv_not_found.

ENDCLASS.


CLASS lcl_app IMPLEMENTATION.

  METHOD run.

    mv_date = sy-datlo.

    DATA(lt_item) = select_items( ).
    mv_selected = lines( lt_item ).

    IF lt_item IS INITIAL.
      MESSAGE s104.
      RETURN.
    ENDIF.

    select_deliveries( IMPORTING et_dlv  = DATA(lt_dlv)
                       CHANGING  ct_item = lt_item ).

    LOOP AT lt_item ASSIGNING FIELD-SYMBOL(<ls_item>).
      DATA(ls_log) = determine( <ls_item> ).
      <ls_item>-gjahr     = ls_log-gjahr.
      <ls_item>-bwtar_new = ls_log-bwtar_new.
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

    " Summaries - go to the job log in background
    MESSAGE s123 WITH mv_dlv_selected mv_dlv_changed mv_batch_changed
                      mv_dlv_errors.
    MESSAGE s103 WITH mv_selected mv_changed mv_unchanged mv_errors.

    display_log( ).

  ENDMETHOD.


  METHOD select_items.

    " Split-valuated materials only: header valuation record (BWTAR =
    " space) with a valuation category.
    " Open quantity: a schedule line not fully received
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
      ORDER BY p~ebeln, p~ebelp
      INTO CORRESPONDING FIELDS OF TABLE @rt_item.

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


  METHOD determine.

    rs_log = VALUE #( scen      = is_item-scen
                      object    = c_object-po_item
                      ebeln     = is_item-ebeln
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
      MESSAGE e107 WITH is_item-werks is_item-mtart rs_log-gjahr
              INTO rs_log-message.
      RETURN.
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
          bwtar_new = <ls_item>-bwtar_new ).

        " 2.1: the batch master is saved before the delivery
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
    IF sy-subrc = 0.
      rv_ok = <ls_buf>-ok.
      RETURN.
    ENDIF.

    INSERT VALUE #( matnr = is_dlv-matnr
                    werks = is_dlv-werks
                    charg = is_dlv-charg )
           INTO TABLE mt_batch_buffer ASSIGNING <ls_buf>.

    DATA(ls_log) = VALUE ty_log( scen      = c_scen-batch
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
                                 bwtar_new = is_item-bwtar_new ).

    SELECT SINGLE bwtar
      FROM mcha
      WHERE matnr = @is_dlv-matnr
        AND werks = @is_dlv-werks
        AND charg = @is_dlv-charg
      INTO @ls_log-bwtar_old.
    IF sy-subrc <> 0.
      ls_log-msgty = 'E'.
      MESSAGE e122 WITH is_dlv-charg |{ is_dlv-matnr ALPHA = OUT }|
                        is_dlv-werks
              INTO ls_log-message.
      APPEND ls_log TO mt_log.
      RETURN.                                " not aligned, buffered
    ENDIF.

    " Same valuation type: batch master unchanged, not logged
    IF ls_log-bwtar_old = ls_log-bwtar_new.
      <ls_buf>-ok = abap_true.
      rv_ok = abap_true.
      RETURN.
    ENDIF.

    IF p_test = abap_true.
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

    cs_log-msgty = 'S'.
    MESSAGE s117 WITH cs_log-bwtar_old cs_log-bwtar_new
            INTO cs_log-message.

  ENDMETHOD.


  METHOD change_delivery.

    DATA ls_vbkok TYPE vbkok.
    DATA lt_vbpok TYPE STANDARD TABLE OF vbpok.
    DATA lt_prot  TYPE STANDARD TABLE OF prott.
    DATA lv_error TYPE abap_bool.
    DATA lv_text  TYPE bapi_msg.

    IF p_test = abap_true.
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
        if_error_messages_send_1 = abap_false
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

    LOOP AT ct_change ASSIGNING <ls_change>.
      <ls_change>-msgty = 'S'.
      MESSAGE s119 WITH <ls_change>-bwtar_old <ls_change>-bwtar_new
              INTO <ls_change>-message.
    ENDLOOP.
    mv_dlv_changed = mv_dlv_changed + lines( ct_change ).

  ENDMETHOD.


  METHOD block_item.

    IF cs_item-blocked_vbeln IS INITIAL.
      cs_item-blocked_vbeln = iv_vbeln.
      cs_item-blocked_posnr = iv_posnr.
    ENDIF.

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
                                     bwtar_new = <ls_member>-bwtar_new ).

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

    TRY.
        cl_salv_table=>factory( IMPORTING r_salv_table = DATA(lo_alv)
                                CHANGING  t_table      = mt_log ).

        lo_alv->get_functions( )->set_all( abap_true ).

        DATA(lo_columns) = lo_alv->get_columns( ).
        lo_columns->set_optimize( abap_true ).
        set_column_text( io_columns = lo_columns
                         iv_name    = 'SCEN'
                         iv_short   = 'Scenario'(t05)
                         iv_medium  = 'Scenario'(t06) ).
        set_column_text( io_columns = lo_columns
                         iv_name    = 'OBJECT'
                         iv_short   = 'Object'(t07)
                         iv_medium  = 'Changed object'(t08) ).
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
    lo_column->set_short_text( CONV #( iv_short ) ).
    lo_column->set_medium_text( CONV #( iv_medium ) ).
    lo_column->set_long_text( CONV #( iv_medium ) ).

  ENDMETHOD.

ENDCLASS.


START-OF-SELECTION.
  NEW lcl_app( )->run( ).
