CLASS zcl_im_mm_po_split_val DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.

  PUBLIC SECTION.
*---------------------------------------------------------------------*
* BAdI ME_PROCESS_PO_CUST - enhancement impl. ZMM_PO_SPLIT_VAL_IMPL
* Default PO item valuation type (BWTAR) from table ZPTP_PO_VALTYPE:
*   1. plant + material type (MARA-MTART) + year
*   2. plant + blank material type + year (plant default)
* Year = year of the PO document date (EKKO-BEDAT), calendar year or
* fiscal year of the company code (C_USE_FISCAL_YEAR).
* Only for split-valuated materials with an existing valuation record.
* Writes BWTAR only, never MWSKZ / TXJCD - runs side by side with the
* SAP Tax Service implementation (BAdI is multiple use).
* Messages: class ZPTP_SPLIT_VAL, 023 and 024.
*---------------------------------------------------------------------*
    INTERFACES if_ex_me_process_po_cust.

  PRIVATE SECTION.

    TYPES:
      BEGIN OF ty_valtype_buffer,
        werks TYPE werks_d,
        mtart TYPE mtart,
        gjahr TYPE gjahr,
        bwtar TYPE bwtar_d,
      END OF ty_valtype_buffer,
      tt_valtype_buffer TYPE HASHED TABLE OF ty_valtype_buffer
                        WITH UNIQUE KEY werks mtart gjahr,

      BEGIN OF ty_mtart_buffer,
        matnr TYPE matnr,
        mtart TYPE mtart,
      END OF ty_mtart_buffer,
      tt_mtart_buffer TYPE HASHED TABLE OF ty_mtart_buffer
                      WITH UNIQUE KEY matnr,

      BEGIN OF ty_split_buffer,
        matnr TYPE matnr,
        bwkey TYPE bwkey,
        split TYPE abap_bool,
      END OF ty_split_buffer,
      tt_split_buffer TYPE HASHED TABLE OF ty_split_buffer
                      WITH UNIQUE KEY matnr bwkey,

      BEGIN OF ty_mbew_buffer,
        matnr  TYPE matnr,
        bwkey  TYPE bwkey,
        bwtar  TYPE bwtar_d,
        exists TYPE abap_bool,
      END OF ty_mbew_buffer,
      tt_mbew_buffer TYPE HASHED TABLE OF ty_mbew_buffer
                     WITH UNIQUE KEY matnr bwkey bwtar,

      BEGIN OF ty_msg_sent,
        id    TYPE mepoitem-id,
        msgno TYPE symsgno,
        key   TYPE string,
      END OF ty_msg_sent,
      tt_msg_sent TYPE HASHED TABLE OF ty_msg_sent
                  WITH UNIQUE KEY id msgno key.

    "! abap_false = only fill BWTAR when empty (user entry wins)
    "! abap_true  = always overwrite with the table value, except on
    "!              items with follow-on documents or delivery completed
    CONSTANTS c_override_user_entry TYPE abap_bool VALUE abap_false.

    "! Warn the user when neither the material type nor the plant
    "! default has an entry for the year
    CONSTANTS c_warn_if_missing TYPE abap_bool VALUE abap_false.

    "! abap_false = ZPTP_PO_VALTYPE-GJAHR is the calendar year of BEDAT
    "! abap_true  = ZPTP_PO_VALTYPE-GJAHR is the fiscal year of BEDAT
    "!              in the item's company code
    CONSTANTS c_use_fiscal_year TYPE abap_bool VALUE abap_false.

    "! Buffers - cleared in OPEN, so each PO sees current data
    DATA mt_valtype_buffer TYPE tt_valtype_buffer.
    DATA mt_mtart_buffer   TYPE tt_mtart_buffer.
    DATA mt_split_buffer   TYPE tt_split_buffer.
    DATA mt_mbew_buffer    TYPE tt_mbew_buffer.

    "! Warnings already issued - process_item runs several times per
    "! item, each warning is raised once per item and content
    DATA mt_msg_sent TYPE tt_msg_sent.

    METHODS get_year
      IMPORTING iv_date         TYPE d
                iv_bukrs        TYPE bukrs
      RETURNING VALUE(rv_gjahr) TYPE gjahr.

    METHODS get_mtart
      IMPORTING iv_matnr        TYPE matnr
      RETURNING VALUE(rv_mtart) TYPE mtart.

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

    METHODS get_bwkey
      IMPORTING iv_werks        TYPE werks_d
      RETURNING VALUE(rv_bwkey) TYPE bwkey.

    METHODS is_split_valuated
      IMPORTING iv_matnr        TYPE matnr
                iv_bwkey        TYPE bwkey
      RETURNING VALUE(rv_split) TYPE abap_bool.

    METHODS valtype_exists
      IMPORTING iv_matnr         TYPE matnr
                iv_bwkey         TYPE bwkey
                iv_bwtar         TYPE bwtar_d
      RETURNING VALUE(rv_exists) TYPE abap_bool.

    METHODS has_follow_on_docs
      IMPORTING iv_ebeln         TYPE ebeln
                iv_ebelp         TYPE ebelp
      RETURNING VALUE(rv_exists) TYPE abap_bool.

    METHODS is_first_warning
      IMPORTING iv_id           TYPE mepoitem-id
                iv_msgno        TYPE symsgno
                iv_key          TYPE string
      RETURNING VALUE(rv_first) TYPE abap_bool.

ENDCLASS.


CLASS zcl_im_mm_po_split_val IMPLEMENTATION.

  METHOD if_ex_me_process_po_cust~open.

    " Reset buffers for each PO
    CLEAR: mt_valtype_buffer,
           mt_mtart_buffer,
           mt_split_buffer,
           mt_mbew_buffer,
           mt_msg_sent.

  ENDMETHOD.


  METHOD if_ex_me_process_po_cust~process_item.

    INCLUDE mm_messages_mac.   " mmpur_* message macros

    " Always read fresh item data - other implementations (e.g. SAP
    " Tax Service) may have changed the item in the same round.
    DATA(ls_item) = im_item->get_data( ).

    " --- Relevance checks ------------------------------------------
    IF ls_item-werks IS INITIAL
    OR ls_item-matnr IS INITIAL
    OR ls_item-loekz IS NOT INITIAL.
      RETURN.
    ENDIF.

    IF ls_item-bwtar IS NOT INITIAL.
      IF c_override_user_entry = abap_false.
        RETURN.                             " keep user / existing value
      ENDIF.
      " Never change BWTAR once GR / IR exist or delivery is completed
      IF ls_item-elikz IS NOT INITIAL
      OR has_follow_on_docs( iv_ebeln = ls_item-ebeln
                             iv_ebelp = ls_item-ebelp ) = abap_true.
        RETURN.
      ENDIF.
    ENDIF.

    " --- Read custom table: plant + material type + year of BEDAT -----
    DATA(lv_mtart) = get_mtart( ls_item-matnr ).

    DATA(lv_bedat) = im_item->get_header( )->get_data( )-bedat.
    IF lv_bedat IS INITIAL.
      lv_bedat = sy-datlo.
    ENDIF.

    DATA(lv_gjahr) = get_year( iv_date  = lv_bedat
                               iv_bukrs = ls_item-bukrs ).

    DATA(lv_bwtar) = get_valtype_from_table( iv_werks = ls_item-werks
                                             iv_mtart = lv_mtart
                                             iv_gjahr = lv_gjahr ).

    IF lv_bwtar IS INITIAL.
      IF c_warn_if_missing = abap_true
      AND is_first_warning( iv_id    = ls_item-id
                            iv_msgno = '024'
                            iv_key   = |{ ls_item-werks }/{ lv_mtart }/{ lv_gjahr }| ) = abap_true.
        mmpur_business_obj_id ls_item-id.
        mmpur_message_forced 'W' 'ZPTP_SPLIT_VAL' '024'
                             ls_item-werks lv_mtart lv_gjahr space.
      ENDIF.
      RETURN.
    ENDIF.

    IF lv_bwtar = ls_item-bwtar.
      RETURN.                               " nothing to change -> no loop
    ENDIF.

    " --- Material must be split-valuated in this valuation area ---------
    DATA(lv_bwkey) = get_bwkey( ls_item-werks ).

    IF is_split_valuated( iv_matnr = ls_item-matnr
                          iv_bwkey = lv_bwkey ) = abap_false.
      RETURN.
    ENDIF.

    " --- Valuation record must exist, otherwise GR will fail ------------
    IF valtype_exists( iv_matnr = ls_item-matnr
                       iv_bwkey = lv_bwkey
                       iv_bwtar = lv_bwtar ) = abap_false.
      IF is_first_warning( iv_id    = ls_item-id
                           iv_msgno = '023'
                           iv_key   = |{ ls_item-matnr }/{ ls_item-werks }/{ lv_bwtar }| ) = abap_true.
        mmpur_business_obj_id ls_item-id.
        " Optional field link - look up the BWTAR constant in type group
        " MMMFD (SE11) and enable: mmpur_metafield mmmfd_<valuation_type>.
        mmpur_message_forced 'W' 'ZPTP_SPLIT_VAL' '023'
                             lv_bwtar ls_item-matnr ls_item-werks space.
      ENDIF.
      RETURN.
    ENDIF.

    " --- Set valuation type -------------------------------------------
    ls_item-bwtar = lv_bwtar.
    im_item->set_data( ls_item ).

  ENDMETHOD.


  METHOD get_year.

    rv_gjahr = iv_date(4).

    IF c_use_fiscal_year = abap_false
    OR iv_bukrs IS INITIAL.
      RETURN.
    ENDIF.

    CALL FUNCTION 'FI_PERIOD_DETERMINE'
      EXPORTING
        i_budat = iv_date
        i_bukrs = iv_bukrs
      IMPORTING
        e_gjahr = rv_gjahr
      EXCEPTIONS
        OTHERS  = 1.
    IF sy-subrc <> 0.
      rv_gjahr = iv_date(4).      " fall back to calendar year
    ENDIF.

  ENDMETHOD.


  METHOD get_mtart.

    READ TABLE mt_mtart_buffer ASSIGNING FIELD-SYMBOL(<ls_buf>)
         WITH TABLE KEY matnr = iv_matnr.
    IF sy-subrc <> 0.
      INSERT VALUE #( matnr = iv_matnr )
             INTO TABLE mt_mtart_buffer ASSIGNING <ls_buf>.

      SELECT SINGLE mtart
        FROM mara
        WHERE matnr = @iv_matnr
        INTO @<ls_buf>-mtart.               " stays initial if not found
    ENDIF.

    rv_mtart = <ls_buf>-mtart.

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


  METHOD get_bwkey.

    " T001W is table-buffered, no own buffer needed
    SELECT SINGLE bwkey
      FROM t001w
      WHERE werks = @iv_werks
      INTO @rv_bwkey.

  ENDMETHOD.


  METHOD is_split_valuated.

    READ TABLE mt_split_buffer ASSIGNING FIELD-SYMBOL(<ls_buf>)
         WITH TABLE KEY matnr = iv_matnr
                        bwkey = iv_bwkey.
    IF sy-subrc <> 0.
      " Header valuation record (BWTAR = space) carries the valuation
      " category
      SELECT SINGLE bwtty
        FROM mbew
        WHERE matnr = @iv_matnr
          AND bwkey = @iv_bwkey
          AND bwtar = @space
        INTO @DATA(lv_bwtty).

      INSERT VALUE #( matnr = iv_matnr
                      bwkey = iv_bwkey
                      split = xsdbool( sy-subrc = 0 AND lv_bwtty IS NOT INITIAL ) )
             INTO TABLE mt_split_buffer ASSIGNING <ls_buf>.
    ENDIF.

    rv_split = <ls_buf>-split.

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


  METHOD has_follow_on_docs.

    " New POs have no number yet (initial or $-temporary) -> no history
    IF iv_ebeln IS INITIAL
    OR iv_ebeln(1) = '$'.
      RETURN.
    ENDIF.

    " Any PO history (GR, IR, ...) blocks a change of the valuation type
    SELECT SINGLE @abap_true
      FROM ekbe
      WHERE ebeln = @iv_ebeln
        AND ebelp = @iv_ebelp
      INTO @rv_exists.

  ENDMETHOD.


  METHOD is_first_warning.

    INSERT VALUE #( id = iv_id msgno = iv_msgno key = iv_key )
           INTO TABLE mt_msg_sent.
    rv_first = xsdbool( sy-subrc = 0 ).

  ENDMETHOD.


  METHOD if_ex_me_process_po_cust~initialize.
    " not used
  ENDMETHOD.


  METHOD if_ex_me_process_po_cust~process_header.
    " not used
  ENDMETHOD.


  METHOD if_ex_me_process_po_cust~process_schedule.
    " not used
  ENDMETHOD.


  METHOD if_ex_me_process_po_cust~process_account.
    " not used
  ENDMETHOD.


  METHOD if_ex_me_process_po_cust~check.
    " not used
  ENDMETHOD.


  METHOD if_ex_me_process_po_cust~post.
    " not used
  ENDMETHOD.


  METHOD if_ex_me_process_po_cust~close.
    " not used
  ENDMETHOD.


  METHOD if_ex_me_process_po_cust~fieldselection_header.
    " not used
  ENDMETHOD.


  METHOD if_ex_me_process_po_cust~fieldselection_header_refkeys.
    " not used
  ENDMETHOD.


  METHOD if_ex_me_process_po_cust~fieldselection_item.
    " not used
  ENDMETHOD.


  METHOD if_ex_me_process_po_cust~fieldselection_item_refkeys.
    " not used
  ENDMETHOD.

ENDCLASS.
