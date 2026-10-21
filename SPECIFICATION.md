# Functional and Technical Specification
## Default valuation type on purchase order items (ZMM_PO_SPLIT_VAL)

| | |
|---|---|
| Area | MM – Purchasing / Inventory valuation |
| Enhancement | BAdI `ME_PROCESS_PO_CUST` |
| Enhancement implementation | `ZMM_PO_SPLIT_VAL_IMPL` |
| Implementing class | `ZCL_IM_MM_PO_SPLIT_VAL` ([source](ZCL_IM_MM_PO_SPLIT_VAL.abap)) |
| Document alignment report | `ZPTP_VALTYPE_DOCSALIGN` ([source](ZPTP_VALTYPE_DOCSALIGN.abap)) |
| Author | kas68 |
| Version | 1.2 |
| Date | 2026-10-21 |

---

# Part 1 – Functional specification

## 1.1 Business requirement

For materials with split valuation, the valuation type (`BWTAR`) must be
entered on each purchase order item; otherwise the goods receipt fails.
Buyers should not have to choose it manually. The valuation type to use depends
on the plant, the material type and the year, and is maintained by the business
in a custom table.

## 1.2 Scope

**In scope**
- Purchase order items created or changed in ME21N / ME22N and through the
  purchase order BAPIs (all go through `ME_PROCESS_PO_CUST`).
- Materials that are split-valuated in the plant's valuation area.
- Alignment of the valuation type of open PO items, of their open inbound
  deliveries and of the batches on these deliveries by report
  `ZPTP_VALTYPE_DOCSALIGN`, in background (also as a job) or online with
  posting row by row (see 1.8).

**Out of scope**
- Items without material (e.g. services, text items), deleted items.
- Tax fields (`MWSKZ`, `TXJCD`) – handled by the SAP Tax Service
  implementation of the same BAdI, which runs side by side.
- Special handling for stock transport orders and account-assigned items
  (they are treated like stock items – see 1.7).

## 1.3 Business rules

| # | Rule |
|---|---|
| R1 | The valuation type is proposed only when the item's valuation type is empty. A value entered by the user is kept (default setting). Exception: R9. |
| R2 | Optional (setting): the table value overwrites a user-entered value, but never on items with PO history (goods receipt, invoice, …) or marked delivery completed. |
| R3 | The year is the year of the PO document date. Fiscal year of the company code by default; optionally the calendar year. |
| R4 | Only active entries (ACTIVE = X) count. Blank plant / material type = all plants / all material types. Lookup order, first hit wins: (1) plant + material type, (2) plant + blank material type, (3) blank plant + material type, (4) blank plant + blank material type; always with the year. |
| R5 | No table entry: the field stays as it is (empty, or a value kept under R1, R2 or R10). Optionally a warning is shown. |
| R6 | The material must be split-valuated in the plant's valuation area; otherwise the valuation type is not set. Warning 107 may still be shown when activated (see 2.7). |
| R7 | The valuation type must exist for the material in the valuation area (not flagged for deletion); otherwise a warning is shown and the field stays empty. |
| R8 | Each warning is shown once per item and content. |
| R9 | New items (PO not yet saved, or new item added in ME22N): on the first processing, a filled valuation type is determined again from the table (setting, on by default). This covers values copied from a reference PO or another item. A value typed by the user before the first Enter, or passed through a BAPI, is overwritten too; a later change by the user is kept. No message is shown when the value is replaced. |
| R10 | If R9 cannot determine a value (no table entry, or the table value has no valuation record) the copied value is kept; if the material is split-valuated and the copied value's own valuation record is missing or flagged for deletion, warning 106 is shown. |

## 1.4 Maintenance of determination data

Table `ZPTP_301_VALTYPE`, maintained in SM30 by the business (client-specific,
customizing request).

| Plant | Mat. type | Year | Val. type | Active | Meaning |
|---|---|---|---|---|---|
| 1000 | ROH | 2026 | NEW | X | Raw materials in plant 1000, POs dated 2026 |
| 1000 | *(empty)* | 2026 | STD | X | All other material types in plant 1000, POs dated 2026 |
| *(empty)* | HALB | 2026 | OWN | X | Semi-finished products in all other plants, POs dated 2026 |
| *(empty)* | *(empty)* | 2026 | STD | X | Global default for 2026 |

A new line per plant (and material type, where needed) must be maintained
for each new year.

## 1.5 Messages

Message class `ZPTP_SPLIT_VAL`, shared with other programs: numbers 000–099
belong to them and must not be reused; this development uses 100 and above.
In the BAdI the messages are type **W**
(warning – the PO can still be saved). Numbers 105 and 108 – 110 are reserved
and must not be reused.

| No. | Text | When |
|---|---|---|
| 100 | Fiscal year not determined for company code &1 and date &2 | Report `ZPTP_VALTYPE_DOCSALIGN` |
| 101 | Valuation type changed from &1 to &2 | Report `ZPTP_VALTYPE_DOCSALIGN` |
| 102 | Test run: valuation type would change from &1 to &2 | Report `ZPTP_VALTYPE_DOCSALIGN` |
| 103 | &1 items selected, &2 changed, &3 already correct, &4 errors | Report `ZPTP_VALTYPE_DOCSALIGN` |
| 104 | No open purchase order items selected | Report `ZPTP_VALTYPE_DOCSALIGN` |
| 106 | Valuation type &1 not defined for material &2 in plant &3 | R7 – valuation record missing; R10 – copied value kept without valuation record; report `ZPTP_VALTYPE_DOCSALIGN` |
| 107 | No valuation type maintained in ZPTP_301_VALTYPE for &1 / &2 / &3 | R5 – no table entry (only if activated); report `ZPTP_VALTYPE_DOCSALIGN` |

Messages of report `ZPTP_VALTYPE_DOCSALIGN` only (texts maintained in SE91):

| No. | Meaning | Variables | When |
|---|---|---|---|
| 117 | Batch valuation type changed | &1 old, &2 new | Batch master changed (D4) |
| 118 | Test run: batch valuation type would change | &1 old, &2 new | Test run / online proposal |
| 119 | Delivery item valuation type changed | &1 old, &2 new | Delivery item changed (D5) |
| 120 | Test run: delivery item valuation type would change | &1 old, &2 new | Test run / online proposal |
| 121 | PO item not changed – delivery item not aligned | &1 delivery, &2 item | D6 |
| 122 | Batch not found | &1 batch, &2 material, &3 plant | Batch master missing (`MCHA`) |
| 123 | Delivery summary | &1 selected, &2 changed, &3 batches changed, &4 errors | End of the run |
| 124 | Batch not aligned – delivery item not changed | &1 batch | D4, D9 |
| 125 | Delivery not changed (no detailed message returned) | &1 delivery | Error of `WS_DELIVERY_UPDATE_2` |
| 126 | Mode *Online* cannot run in background | – | Online mode scheduled as a job or started in background |
| 127 | Select at least one proposed change not yet posted | – | Online: *Post* without a postable row |
| 128 | Posting summary | &1 posted, &2 errors | Online: after *Post* |
| 129 | Change not confirmed on the database | &1 expected, &2 found | Real change: valuation type read back after the commit differs |
| 130 (W) | Goods receipt posted – item not changed | &1 material document | Option *Items with goods receipt*: item partially or fully received, listed only |
| 131 | Rows with goods receipt cannot be posted | &1 number of such rows | Online: *Post* with a selection containing an item with goods receipt – nothing posted |

## 1.6 Settings

| Setting | Default | Effect |
|---|---|---|
| Override user entry | Off | On = rule R2 applies. Must stay **Off** while a report changes the valuation type with `BAPI_PO_CHANGE` (e.g. `ZPTP_VALTYPE_DOCSALIGN`; see 2.8). |
| Warn if no table entry | Off | On = message 107 is shown |
| Use fiscal year | On | On = the table holds fiscal years of the company code; Off = calendar years |
| Determine again on new items | On | On = rule R9 applies; Off = a copied value counts as a user entry |

Settings are constants in the class (see 2.4); a change requires a transport.

## 1.7 Assumptions and open points

- Stock transport orders and account-assigned items are treated like stock
  items. To be confirmed by the business.
- Warning 106 is not yet linked to the valuation type field on screen (see 2.7).
- Warning 107, if activated, is also shown for materials without split
  valuation (see 2.7). To be fixed before the setting is switched on.
- Report `ZPTP_VALTYPE_DOCSALIGN`, online mode: dependent objects are not
  added automatically – a delivery item with a batch needs the batch row
  posted first (or in the same selection), a PO item its delivery rows (D9).

## 1.8 Document alignment report `ZPTP_VALTYPE_DOCSALIGN`

**Purpose** – The BAdI sets the valuation type when the PO is entered. The
report aligns, for the fiscal year of the run date, the valuation type of open
PO items with `ZPTP_301_VALTYPE`, together with their open inbound deliveries
and the batches on these deliveries – for example at the start of a new fiscal
year, before goods receipt.

**Selection screen**

| Field | Type | Meaning |
|---|---|---|
| Plant | Select-option (frame *Selection*), default `8Q01` | `EKPO-WERKS` |
| Purchase order | Select-option (frame *Selection*) | `EKPO-EBELN` |
| Items with goods receipt | Checkbox (frame *Selection*), default **off** | Also lists split-valuated PO items with a goods receipt (`EKET-WEMNG > 0`), partially or fully received – warning 130, never changed or posted. Without the option these items are not selected (items with a goods receipt are never changed, nor their deliveries and batches). Adds the column *Material document* (last goods receipt, `EKBE`, `VGABE = 1`, not reversals) for all listed items. |
| Background | Radio button (frame *Run mode*) | All changes in one run (also as a background job) |
| Online | Radio button (frame *Run mode*), default | Proposals in an ALV, posted row by row |
| Test run | Checkbox, default **on** | Background mode only: no change, shows what would change. Not ready for input in online mode. |

**Rules**

| # | Rule |
|---|---|
| D1 | Open PO item: standard PO, PO and item not deleted, not delivery completed, no return item, quantity still to be received on a schedule line, no goods receipt yet (partially received items are not changed). Only split-valuated materials. |
| D2 | The year is the fiscal year of the run date in the item's company code (error 100 if not determined). The valuation type is read with the lookup order R4 (error 107 if none) and must have its own valuation record (error 106). An item in error is not processed, nor are its deliveries. |
| D3 | Scenario 1 – item without inbound delivery: only the PO item is changed. Scenario 2 – item with inbound deliveries: only delivery items without goods receipt are processed; 2.1 with batch, 2.2 without batch. |
| D4 | 2.1: the batch master is changed first if its valuation type differs (once per batch); if this fails, the delivery item is not changed (124). |
| D5 | The delivery items are changed together per delivery: all or none. |
| D6 | Order of the changes: all batches, then all delivery items, then the PO items – also within the same PO. The PO item is changed only when all its open delivery items are aligned (otherwise 121), so it gets the valuation type of its deliveries. All items of one PO are changed together, without output to the vendor. |
| D7 | Objects that already have the right valuation type are not changed and not listed (PO items are counted as already correct). |
| D8 | Background mode: test run = everything checked, nothing saved. |
| D9 | Online mode: the program first runs as a test run; each change found is a proposal. The user selects rows and chooses *Post* (confirmation popup). The selected rows are posted in the order batches → delivery items → PO items. A delivery item with a batch is posted only if the batch already has the new valuation type (124); a PO item with deliveries only if all its open delivery items have it (121) – both read again from the database. A failed row can be posted again; errors of the simulation cannot be posted. |
| D10 | Online mode cannot run in background (126). |

**Output**

- Summary messages 123 (deliveries) and 103 (PO items). Online: status bar;
  background: job log.
- ALV list of changes (or proposed changes) and errors: plant (first column),
  status light (green = success / proposal, yellow = warning, red = error),
  PO, object (PO item, delivery, batch), PO item, delivery, delivery item,
  material document (last goods receipt, only with option *Items with goods
  receipt*),
  material, batch, material type, fiscal year, one old / new pair of columns
  per object, scenario, message and message type (before *Posted*). Sorted by PO number ascending and grouped by
  PO (number shown once, line after each PO), then in processing order:
  batches, delivery items, PO items, each by item; the item number is shown on
  every line:

  | Column | Filled for |
  |---|---|
  | Purchase order valuation type (old / new) | PO item lines |
  | Delivery note valuation type (old / new) | Delivery item lines |
  | Batch valuation type (old / new) | Batch lines |

- The *new* cell is **yellow** for a change that would be made (test run,
  online proposal) and **green** for a real change (background or posted
  online) confirmed on the database: after the commit the batch (`MCHA`),
  delivery item (`LIPS`) or PO item (`EKPO`) is read again and must have the
  new valuation type; otherwise the line is an error (129). Error lines are
  not coloured.
- Online mode only: column *Posted* (checkbox), rows selectable, function
  *Post* in the toolbar; after posting, message 128 and the list is refreshed.
- Background: list in the spool of the job. No application log (SLG1); changes
  are traceable in the change documents of the PO, delivery and batch.

---

# Part 2 – Technical specification

## 2.1 Object list

| Object | Type | Transaction | Name |
|---|---|---|---|
| BAdI definition | New BAdI (migrated classic BAdI), multiple use | SE18 | `ME_PROCESS_PO_CUST` |
| Enhancement implementation | Enhancement implementation | SE19 | `ZMM_PO_SPLIT_VAL_IMPL` |
| BAdI implementation | BAdI implementation | SE19 | `ZMM_PO_SPLIT_VAL_IMPL` |
| Implementing class | Global class | SE24 | `ZCL_IM_MM_PO_SPLIT_VAL` |
| Custom table | Transparent table, delivery class C | SE11 | `ZPTP_301_VALTYPE` |
| Maintenance function group | Table maintenance generator | SE11 / SE80 | `ZPTP_301_VALTYPE` |
| Message class | Message class | SE91 | `ZPTP_SPLIT_VAL` |
| Document alignment report | Executable program | SE38 | `ZPTP_VALTYPE_DOCSALIGN` |
| GUI status of the report (online mode) | GUI status | SE41 | `ZSALV_POST` |

## 2.2 Table `ZPTP_301_VALTYPE`

| Field | Key | Data element | Check table | Remark |
|---|---|---|---|---|
| MANDT | X | MANDT | | |
| WERKS | X | WERKS_D | T001W | Empty = all plants. Foreign key without **Check required**. |
| MTART | X | MTART | T134 | Empty = all material types. Foreign key without **Check required**. |
| GJAHR | X | GJAHR | | Calendar or fiscal year (setting) |
| BWTAR | | BWTAR_D | T149D | Destination valuation type |
| DESCR | | TEXT40 | | Comment |
| ACTIVE | | XFELD | | Entry active; inactive entries are ignored |

Technical settings: data class APPL2, size category 0, buffering not allowed
(the class buffers the data per PO).

Table maintenance: authorization group `&NC&` (or project-specific), function
group `ZPTP_301_VALTYPE`, one-step, standard recording routine.

## 2.3 Data sources

| Data | Source |
|---|---|
| Item data | `IM_ITEM->GET_DATA( )` (structure `MEPOITEM`) |
| PO document date | `IM_ITEM->GET_HEADER( )->GET_DATA( )-BEDAT`; fallback `SY-DATLO` |
| Fiscal year | FM `FI_PERIOD_DETERMINE` (company code `MEPOITEM-BUKRS`); fallback calendar year |
| Material type | `MARA-MTART` |
| Valuation area | `T001W-BWKEY` |
| Split valuation | `MBEW-BWTTY` of the header record (`BWTAR = space`) |
| Valuation record | `MBEW` with `BWTAR`, `LVORM = space` |
| PO history | `EKBE` (any record for `EBELN` / `EBELP`) |
| New item | PO number initial or `$`-temporary, or no `EKPO` record for `EBELN` / `EBELP` |

## 2.4 Class `ZCL_IM_MM_PO_SPLIT_VAL`

Implements `IF_EX_ME_PROCESS_PO_CUST` (13 methods). Only `OPEN` and
`PROCESS_ITEM` contain logic; the other methods are empty.

**Constants (private section)**

| Constant | Default | Functional setting |
|---|---|---|
| `C_OVERRIDE_USER_ENTRY` | `abap_false` | Override user entry (R2) |
| `C_WARN_IF_MISSING` | `abap_false` | Warn if no table entry (message 107) |
| `C_USE_FISCAL_YEAR` | `abap_true`  | Use fiscal year (R3) |
| `C_REDETERMINE_NEW_ITEMS` | `abap_true` | Determine again on new items (R9) |

**Methods**

| Method | Visibility | Purpose |
|---|---|---|
| `IF_EX_ME_PROCESS_PO_CUST~OPEN` | public | Clears all buffers for each PO |
| `IF_EX_ME_PROCESS_PO_CUST~PROCESS_ITEM` | public | Main logic (2.5) |
| `GET_YEAR` | private | Calendar or fiscal year of a date |
| `GET_MTART` | private | Material type from `MARA` (buffered) |
| `GET_VALTYPE_FROM_TABLE` | private | Lookup order R4 |
| `READ_VALTYPE` | private | Single read of `ZPTP_301_VALTYPE` (buffered) |
| `GET_BWKEY` | private | Valuation area of the plant |
| `IS_SPLIT_VALUATED` | private | Split valuation check (buffered) |
| `VALTYPE_EXISTS` | private | Valuation record check (buffered) |
| `HAS_FOLLOW_ON_DOCS` | private | PO history check; skipped for new POs |
| `GET_ITEM_STATE` | private | First processing of the item and new-item flag (buffered per item) |
| `WARN_IF_VALTYPE_INVALID` | private | Warning 106 for a kept copied value (R10) |
| `IS_FIRST_WARNING` | private | Issues each warning once (R8) |

## 2.5 Processing logic – `PROCESS_ITEM`

1. Read the item with `GET_DATA( )`. Always read it fresh: other
   implementations may have changed the item in the same round.
2. Exit if plant or material is empty, or the item is deleted (`LOEKZ`).
3. Determine with `GET_ITEM_STATE` whether this is the first processing of a
   new item. If so and `C_REDETERMINE_NEW_ITEMS` is set, skip step 4 (R9).
4. If `BWTAR` is filled:
   - exit if `C_OVERRIDE_USER_ENTRY = abap_false`;
   - otherwise exit if `ELIKZ` is set or `HAS_FOLLOW_ON_DOCS` returns true.
5. Determine material type, PO document date and year.
6. Read the valuation type with `GET_VALTYPE_FROM_TABLE`. If empty: message 107
   (if activated); on re-determination, `WARN_IF_VALTYPE_INVALID` (R10); exit.
7. Exit if the value equals the current `BWTAR`. This prevents endless
   re-processing after `SET_DATA`.
8. Exit if the material is not split-valuated (`IS_SPLIT_VALUATED`).
9. If `VALTYPE_EXISTS` returns false: message 106; on re-determination,
   `WARN_IF_VALTYPE_INVALID` (R10); exit.
10. Set `BWTAR` and call `IM_ITEM->SET_DATA( )`.

Messages are raised with the macros of include `MM_MESSAGES_MAC`
(`mmpur_business_obj_id`, `mmpur_message_forced`), linked to the item ID.

## 2.6 Buffering and performance

- Hashed-table buffers per PO for the custom table, material type,
  split-valuation check and valuation records. "Not found" is buffered too.
- Buffers are instance attributes, cleared in `OPEN`. This relies on the BAdI
  instance being reused within a PO. If SE18 shows *creation of new instances*,
  the buffers must become `CLASS-DATA` (warnings may repeat and the buffers
  have no effect). This also affects R9: without a reused instance every
  processing counts as the first one, so a user could no longer change the
  valuation type on new items.
- `EKPO` is read once per item and PO (new-item check), only for items of a
  saved PO.
- `T001W` is SAP-buffered; no own buffer.
- `EKBE` is read only in override mode for items that already have a valuation
  type.

## 2.7 Known limitations

- Warning 106 has no field link: the `mmpur_metafield` line in `PROCESS_ITEM`
  is commented out until the `MMMFD` constant for `BWTAR` is confirmed.
- Changes to `ZPTP_301_VALTYPE` during an open PO become visible with the next PO.
- SAP leaves no copy marker on a PO item, so R9 cannot tell a copied value from
  one typed by the user or passed through a BAPI before the first processing.
- R9 does not cover a change of `BEDAT` into another year after the first
  processing of the item.
- R9 does not cover a change of material or plant on a new item after its
  first processing: a filled valuation type is then kept like a user entry.
- The table lookup (step 6) runs before the split-valuation check (step 8).
  With `C_WARN_IF_MISSING` on, warning 107 is therefore also shown for
  materials that are not split-valuated, in a plant / year without a table
  line. No impact with the default setting (off); before switching it on, the
  split-valuation check must move before the table lookup.
- The protection of R2 (delivery completed, PO history) applies only to items
  whose valuation type is already filled. An item with an empty valuation
  type is filled even if it is flagged delivery completed.
- Message variables are passed in internal format: in warning 106, a numeric
  material number (&2) is shown with leading zeros.
- Comments must stay inside class sections or methods. Comments outside them
  cause the error *"The class contains unknown comments which can't be stored"*.

## 2.8 Interaction with reports using `BAPI_PO_CHANGE`

`BAPI_PO_CHANGE` runs the BAdI. When a report (e.g. `ZPTP_VALTYPE_DOCSALIGN`)
changes the valuation type of a saved item, its `BWTAR` is filled, so with
`C_OVERRIDE_USER_ENTRY = abap_false` the BAdI keeps the value passed by the
report. With the setting on, the BAdI would replace it with the value for
the PO document date.

## 2.9 Report `ZPTP_VALTYPE_DOCSALIGN`

Executable program with message class `ZPTP_SPLIT_VAL` (`MESSAGE-ID`) and one
local class `LCL_APP`. The table lookup, the valuation record check and their
buffers are copies of the BAdI class logic (the class methods are private).

**Selection screen**

| Name | Definition |
|---|---|
| `S_WERKS` | `SELECT-OPTIONS FOR ekpo-werks DEFAULT '8Q01'`, block `B01` with frame |
| `S_EBELN` | `SELECT-OPTIONS FOR ekpo-ebeln`, block `B01` |
| `P_GR` | `PARAMETERS AS CHECKBOX`, default off, block `B01` |
| `P_BGD` | Radio button group `MODE`, `USER-COMMAND mode`, block `B02` with frame |
| `P_ONL` | Radio button group `MODE`, default, block `B02` |
| `P_TEST` | Checkbox, default `abap_true`, `MODIF ID tst`, block `B02` |

Events:
- `AT SELECTION-SCREEN OUTPUT` – `P_TEST` not ready for input when `P_ONL` is
  set.
- `AT SELECTION-SCREEN` – error 126 when `P_ONL` is set and the job is
  scheduled (`SJOB`).
- `START-OF-SELECTION` – `NEW lcl_app( )->run( )`; error 126 when `P_ONL` is
  set and `SY-BATCH` is set.

**Methods of `LCL_APP`**

| Method | Purpose |
|---|---|
| `RUN` | Simulation flag, selection, determination, `ALIGN_DELIVERIES`, `UPDATE_PURCHASE_ORDERS`, summaries, `DISPLAY_LOG` |
| `SELECT_ITEMS` | Open PO items (D1), one SELECT |
| `SELECT_DELIVERIES` | Open inbound delivery items (`EKES` → `LIPS`/`LIKP`, `VBTYP = '7'`, `WBSTA <> 'C'`; batch split: sub-items only); sets the scenario |
| `DETERMINE` | Fiscal year, valuation type and checks for one PO item (D2) |
| `ALIGN_DELIVERIES` / `ALIGN_BATCH` | Scenario 2 per delivery: batches first (buffered per batch), then `CHANGE_DELIVERY` |
| `CHANGE_BATCH` | `BAPI_BATCH_CHANGE` (`VAL_TYPE`), commit or rollback |
| `CHANGE_DELIVERY` | `WS_DELIVERY_UPDATE_2` for all items of one delivery (`VBPOK-BWTAR`, batch passed again), commit; then `LE_DELIVERY_REFRESH_BUFFER` |
| `BLOCK_ITEM` | Marks the PO item as blocked by a delivery item not aligned (D6) |
| `UPDATE_PURCHASE_ORDERS` / `CHANGE_PO` | `BAPI_PO_CHANGE` per PO (`VAL_TYPE`, `TESTRUN`, `NO_MESSAGING`), commit or rollback |
| `GET_FISCAL_YEAR` | `FI_PERIOD_DETERMINE` for the run date, buffered per company code |
| `GET_VALTYPE_FROM_TABLE` / `READ_VALTYPE` | Lookup order R4, buffered |
| `VALTYPE_EXISTS` | Valuation record check, buffered |
| `DISPLAY_LOG` / `BUILD_OUTPUT` / `SET_COLUMN_TEXT` | ALV output (`CL_SALV_TABLE`): output table `MT_OUT` built from the log `MT_LOG` (each line keeps its `MT_LOG` line in the technical column `LOGIDX`), sorted in the program by `EBELN`, object (batch, delivery, PO item – hidden column `RANK`) and `EBELP` and in the ALV by `EBELN` (grouped, with underline) and the hidden column `SEQ` (`EBELP` is no ALV sort column, otherwise repeated item numbers would be suppressed), status light in the exception column `LIGHT` (from `MSGTY`: E/A red, W yellow, S green), cell colours in `T_COLOR` (`COL_TOTAL` yellow, `COL_POSITIVE` green when the change was read back from the database – log field `VERIFIED`, set in `CHANGE_BATCH`, `CHANGE_DELIVERY`, `CHANGE_PO`) |
| `ON_ADDED_FUNCTION` | Online: handler of function `POST`; posts the selected rows, rebuilds `MT_OUT`, refreshes the ALV |
| `POST_SELECTED` | Online: selected rows with an open proposal (`TODO`), confirmation popup, then `POST_BATCHES`, `POST_DELIVERIES`, `POST_PURCHASE_ORDERS`; marks the rows posted; message 128 |
| `POST_BATCHES` | `CHANGE_BATCH` per selected batch row |
| `POST_DELIVERIES` | Per delivery: batch read again from `MCHA` (124 if not aligned), then `CHANGE_DELIVERY` for the selected items |
| `POST_PURCHASE_ORDERS` | Open delivery items read again (`SELECT_DELIVERIES`; 121 if one is not aligned), then `CHANGE_PO` per PO for the selected items |

**Simulation flag** – `MV_TEST` replaces `P_TEST` in the change methods: `P_TEST`
in background mode, always on for the online proposal, off when posting from
the ALV.

**Online mode** – after the simulation, all log lines of type S are marked as
open proposals (`TODO`). The ALV uses GUI status `ZSALV_POST` (copy of
`STANDARD_FULLSCREEN` of program `SAPLSLVC_FULLSCREEN` with function `POST`),
selection mode `ROW_COLUMN` and the handler of event `ADDED_FUNCTION`. The ALV
sorts `MT_OUT`, so a selected row is mapped to its `MT_LOG` line through
`LOGIDX`. A posted line gets `POSTED` and loses `TODO`; a
failed line gets type E and keeps `TODO`.

**Known limitations**

- Year: fiscal year of the run date only, no key date and no fallback to the
  calendar year.
- Between the proposal and the posting, the data are not locked; only the
  dependencies (batch, open delivery items) are read again.
- A delivery item can only be changed while it has no goods receipt; a batch
  only while SAP accepts the change (e.g. no stock).
- Empty select-options select all open POs of the system.

---

# Part 3 – Implementation

1. **Table** – create `ZPTP_301_VALTYPE` as in 2.2 and activate. If the table
   already exists without `MTART`: add the field, activate, adjust the database
   in SE14 (existing rows become plant defaults).
2. **Maintenance view** – SE11 → Utilities → Table Maintenance Generator, with
   the settings in 2.2. After table changes: **Change** → **New field/sec. table
   in structure**.
3. **Message class** – add messages 106 and 107 to the existing (shared) class
   `ZPTP_SPLIT_VAL` (1.5).
   Keep the placeholder order:
   - 106: &1 = valuation type, &2 = material, &3 = plant
   - 107: &1 = plant, &2 = material type, &3 = year
4. **BAdI definition** – in SE18, display `ME_PROCESS_PO_CUST` and note the
   enhancement spot and the instance creation mode (2.6).
5. **BAdI implementation** – SE19 → Create Implementation → New BAdI → enhancement
   spot from step 4:
   - enhancement implementation `ZMM_PO_SPLIT_VAL_IMPL`;
   - BAdI implementation `ZMM_PO_SPLIT_VAL_IMPL`, BAdI definition
     `ME_PROCESS_PO_CUST`, class `ZCL_IM_MM_PO_SPLIT_VAL`;
   - don't activate yet; don't create a classic implementation as well.
6. **Class code** – in SE24 (Source Code-Based) or ADT, replace the source with
   [ZCL_IM_MM_PO_SPLIT_VAL.abap](ZCL_IM_MM_PO_SPLIT_VAL.abap), set the constants,
   check syntax and activate (select all inactive objects).
7. **Activate the implementation** – SE19, **Implementation is active** ticked,
   activate. Expected: status Active; the 13 interface methods green, the 11
   helper methods red (red = not part of the BAdI interface, not an error).
8. **Data** – maintain `ZPTP_301_VALTYPE` in SM30 (1.4).
9. **Messages of report `ZPTP_VALTYPE_DOCSALIGN`** – add messages 100 to 104
   to `ZPTP_SPLIT_VAL` (1.5). Keep the placeholder order:
   - 100: &1 = company code, &2 = date
   - 101, 102: &1 = old valuation type, &2 = new valuation type
   - 103: &1 = selected, &2 = changed, &3 = already correct, &4 = errors

   Then add messages 117 to 131 with the placeholders of 1.5.
10. **Report** – SE38, create executable program `ZPTP_VALTYPE_DOCSALIGN`,
    paste [ZPTP_VALTYPE_DOCSALIGN.abap](ZPTP_VALTYPE_DOCSALIGN.abap).
11. **GUI status** – SE41 (or SE80): copy status `STANDARD_FULLSCREEN` of
    program `SAPLSLVC_FULLSCREEN` to program `ZPTP_VALTYPE_DOCSALIGN`, status
    `ZSALV_POST`; add function code `POST` (text *Post selected*, with an
    icon) to the application toolbar; activate.
12. **Text elements** – selection texts: `S_WERKS` Plant, `S_EBELN` Purchase
    order, `P_GR` Items with goods receipt, `P_BGD` Background, `P_ONL` Online (post row by row), `P_TEST` Test
    run. Text symbols: `B01` *Selection*, `B02` *Run mode*, `T05` – `T08`,
    `T11` – `T40` (ALV headings and confirmation popup): create them from the
    source by double-click. Check syntax and activate.
13. **Background job** – create a variant (mode *Background*, test run off) and
    schedule it in SM36. Run it first with test run on and check the spool.

---

# Part 4 – Test cases

Prerequisite: a material split-valuated in the test plant (MM03, Accounting 1:
valuation category set, valuation types with their own accounting records).

| # | Case | Expected |
|---|---|---|
| T1 | Material type has its own table line, valuation type field empty | Valuation type from the material-type line |
| T2 | Material type without its own line, plant default exists | Valuation type from the plant default line |
| T3 | No line at all (warning setting on) | Warning 107 once; field stays empty |
| T4 | User enters a valuation type (override off) | User's value is kept |
| T5 | Material without split valuation | Nothing happens |
| T6 | Table value has no valuation record for the material | Warning 106 once; field stays empty |
| T7 | PO document date in another year | Line for that year is used |
| T8 | ME22N on an item with a goods receipt (override on) | Valuation type isn't changed |
| T9 | Item with tax code / jurisdiction | Tax fields unchanged |
| T10 | ME21N with reference to a PO of the previous year (valuation type filled) | Valuation type of the current year from the table, no message |
| T11 | As T10, then the user changes the valuation type and presses Enter | User's value is kept |
| T12 | As T10, no table entry for the current year; copied valuation type flagged for deletion in `MBEW` | Copied value kept; warning 106 once |
| T13 | ME22N: copy an item within a saved PO | New item gets the table value; the original item is unchanged |
| T14 | `BAPI_PO_CREATE1` with `BWTAR` filled and a table entry | Table value replaces the BAPI value (R9) |

Debugging: breakpoint in `IF_EX_ME_PROCESS_PO_CUST~PROCESS_ITEM`.

**Report `ZPTP_VALTYPE_DOCSALIGN`**

| # | Case | Expected |
|---|---|---|
| D-T1 | Background, test run; open PO item without delivery, other valuation type in the table | PO line with message 102, new PO cell yellow; PO unchanged |
| D-T2 | As D-T1, test run off | Message 101; valuation type changed (ME23N change document) |
| D-T3 | PO item with an open inbound delivery item with batch; batch, delivery and PO with the old valuation type; test run off | Batch (117), delivery item (119) and PO item (101) changed, in this order; three lines, new cells green (read back from the database) |
| D-T4 | As D-T3, batch cannot be changed (e.g. stock) | Batch line E; delivery item 124; PO item 121; nothing else changed |
| D-T5 | Delivery item with goods receipt | Not processed |
| D-T6 | No table entry / no valuation record | Error 107 / 106; nothing changed for the item and its deliveries |
| D-T7 | Online mode | *Test run* not ready for input; ALV with selectable rows, column *Posted*, function *Post*; proposals yellow |
| D-T8 | Online: select a batch line and its delivery line, *Post*, confirm | Both posted, new cells green, *Posted* ticked; message 128 |
| D-T9 | Online: select only a delivery line whose batch is not aligned | Error 124 on the line; delivery unchanged; can be posted again after the batch |
| D-T10 | Online: select only a PO line whose delivery is not aligned | Error 121 on the line; PO unchanged |
| D-T11 | Online: *Post* without selection, or only posted / error lines | Message 127; nothing changed |
| D-T12 | Online: *Post*, then answer *No* in the popup | Nothing changed |
| D-T13 | Online mode scheduled with F9 / variant in SM36 | Error 126 |
| D-T14 | Background job, mode *Background* | Summaries 123 and 103 in the job log, list in the spool |
| D-T15 | Real change (background or online) whose valuation type is not on the database after the commit | Line red with message 129; online: can be posted again; background: PO item not changed if a delivery item fails (121) |
| D-T16 | Option *Items with goods receipt*; PO item fully or partially received | Line yellow (warning 130) with old / determined new valuation type and the GR material document; *Post* with this row selected (alone or with other rows) refused with 131, nothing posted; PO unchanged |
| D-T17 | Option off; PO item partially received, other valuation type in the table | Item not listed and not changed (nor its deliveries and batches) |

---

# Part 5 – Transport

| Request | Content |
|---|---|
| Workbench | Table `ZPTP_301_VALTYPE`, function group `ZPTP_301_VALTYPE`, message class `ZPTP_SPLIT_VAL`, class `ZCL_IM_MM_PO_SPLIT_VAL`, enhancement implementation `ZMM_PO_SPLIT_VAL_IMPL`, report `ZPTP_VALTYPE_DOCSALIGN` (with text elements and GUI status `ZSALV_POST`) |
| Customizing | SM30 entries of `ZPTP_301_VALTYPE` (client-specific – transport or maintain in each client and system) |

Import order: table and message class → class → enhancement implementation →
report (or everything on one request). Variants and background jobs are not
transported; create them in each system.
