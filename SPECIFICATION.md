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
| Version | 1.6 |
| Date | 2026-10-22 |

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
  posting row by row (see 1.8 and 1.9).

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
(warning – the PO can still be saved). Numbers 105, 108 – 110 and 135 are reserved
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
| 132 | Existing batch without valuation type | &1 batch | D11: batch with material movements, `MCHA-BWTAR` empty – PO item error |
| 133 | Batch &1 (&2) and batch &3 (&4) differ | &1 batch, &2 valuation type, &3 batch, &4 valuation type | D11: two existing batches of one PO item disagree – PO item error |
| 134 (I) | Batch &1 used: valuation type &2 kept | &1 batch, &2 valuation type | D11: batch line, batch master not changed |
| 136 (I) | Valuation type &1 already correct | &1 valuation type | D7: object of a listed flow that needs no change – display only |

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
- Report `ZPTP_VALTYPE_DOCSALIGN`: a batch counts as *existing* when it has
  any material document item (`MSEG`, reversals included) for the same
  material and plant – movements of the same batch number in other plants are
  not considered. To be confirmed by the business.
- Report `ZPTP_VALTYPE_DOCSALIGN`: when a PO item has both an existing and a
  new batch, the new batch is changed to the valuation type of the existing
  one (not to the table value), so that the PO item has one valuation type
  for all its goods receipts (D11). To be confirmed by the business.
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
| Inbound delivery | Select-option (frame *Selection*) | `LIKP-VBELN`. Selects the PO items that have a confirmation (`EKES`) with an inbound delivery in the range. The whole flow of these PO items is processed – also their open delivery items outside the range, so that the PO item stays aligned with all its deliveries (D6). Items with goods receipt (option) are filtered the same way. |
| Items with goods receipt | Checkbox (frame *Selection*), default **off** | Also lists split-valuated PO items with a goods receipt (`EKET-WEMNG > 0`), partially or fully received – warning 130, never changed or posted. Without the option these items are not selected (items with a goods receipt are never changed, nor their deliveries and batches). Adds the column *Material document* (last goods receipt, `EKBE`, `VGABE = 1`, not reversals) for all listed items. |
| Aligned flows | Checkbox (frame *Selection*), default **off** | Also lists the flows (PO item, its open delivery items and their batches) where every object already has the right valuation type – lines 136, display only, never changed or posted. Without the option these flows are not listed (D7). |
| Background | Radio button (frame *Run mode*) | All changes in one run (also as a background job) |
| Online | Radio button (frame *Run mode*), default | Proposals in an ALV, posted row by row |
| Test run | Checkbox, default **on** | Background mode only: no change, shows what would change. Not ready for input in online mode. |

**Rules**

| # | Rule |
|---|---|
| D1 | Open PO item: standard PO, PO and item not deleted, not delivery completed, no return item, quantity still to be received on a schedule line, no goods receipt yet (partially received items are not changed). Only split-valuated materials. |
| D2 | The year is the fiscal year of the run date in the item's company code (error 100 if not determined). The valuation type is read with the lookup order R4 (error 107 if none) and must have its own valuation record (error 106). An item in error is not processed, nor are its deliveries. |
| D3 | Scenario 1 – item without inbound delivery: only the PO item is changed. Scenario 2 – item with inbound deliveries: only delivery items without goods receipt are processed; 2.1 with a new batch, 2.2 without batch, 2.3 with an existing batch (D11). |
| D4 | 2.1: the batch master of a new batch (no material movement in the plant) is changed first if its valuation type differs (once per batch); if this fails, the delivery item is not changed (124). |
| D5 | The delivery items are changed together per delivery: all or none. |
| D6 | Order of the changes: all batches, then all delivery items, then the PO items – also within the same PO. The PO item is changed only when all its open delivery items are aligned (otherwise 121), so it gets the valuation type of its deliveries. All items of one PO are changed together, without output to the vendor. |
| D7 | Objects that already have the right valuation type are never changed. *Flow* = a PO item, its open delivery items and their batches. When at least one object of a flow is listed (change, proposal, error, information 134), the objects of the flow that need no change are listed too (136, no status light, no colour): display only – not processed in background, not postable online. When no object of the flow is listed, nothing is listed (the PO item is counted as already correct, 103), unless option *Aligned flows* is set: then all objects of the flow are listed with 136. |
| D8 | Background mode: test run = everything checked, nothing saved. |
| D9 | Online mode: the program first runs as a test run; each change found is a proposal. The user selects rows and chooses *Post* (confirmation popup). The selected rows are posted in the order batches → delivery items → PO items. A delivery item with a batch is posted only if the batch already has the new valuation type (124); a PO item with deliveries only if all its open delivery items have it (121) – both read again from the database. A failed row can be posted again; errors of the simulation cannot be posted. |
| D10 | Online mode cannot run in background (126). |
| D11 | 2.3 – existing batch (at least one material movement of the batch in the plant): the batch master is **never** changed. Its valuation type (`MCHA-BWTAR`) replaces the table value for the PO item: the delivery items of the PO item (if different) and the PO item get it; new batches of the same PO item too. No table lookup is needed (errors 100 / 107 do not apply); the valuation record check (106) still applies. The batch is listed once as information (134). Errors on the PO item: existing batch without valuation type (132), existing batches with different valuation types (133) – the item and its deliveries are then not processed. |

**Output**

- Summary messages 123 (deliveries) and 103 (PO items). Online: status bar;
  background: job log.
- ALV list of changes (or proposed changes) and errors: plant (first column),
  status light (green = success / proposal, yellow = warning, red = error,
  none = information only: existing batch 134, already correct 136),
  PO, object (PO item, delivery, batch), PO item, delivery, delivery item,
  material document (last goods receipt, only with option *Items with goods
  receipt*),
  material, batch, material type, fiscal year, one old / new pair of columns
  per object, *Batch with movement* (checkbox, batch lines only: ticked when the
  batch has a material movement in the plant, scenario 2.3), reference
  (`TABLE` / `BATCH`), scenario, message and message type (before *Posted*). Sorted by PO number ascending and grouped by
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
- **Orange** marks the valuation types taken from an existing batch (D11):
  - on the batch line (134, batch master not changed), the cells *Bat VT
    old* and *Bat VT new*;
  - the *new* cell of delivery and PO lines is orange instead of yellow for a
    change that would be made; a real change confirmed on the database stays
    green;
  - no other cell or line is orange. Column *Reference* (after the batch
    columns) shows `TABLE` or `BATCH`, without colour.
- Lines with 136 (already correct, D7) have no status light and no colour.
- Online mode only: column *Posted* (checkbox), rows selectable, function
  *Post* in the toolbar; after posting, message 128 and the list is refreshed.
- Background: list in the spool of the job. No application log (SLG1); changes
  are traceable in the change documents of the PO, delivery and batch.

## 1.9 Scenarios of report `ZPTP_VALTYPE_DOCSALIGN`

The scenario is shown in the column *Scenario* of the list. *Old* is the
valuation type on the document, *new* the one determined from
`ZPTP_301_VALTYPE` for the PO item (D2). Delivery items and batches always get
the new valuation type of their PO item.

**Main scenarios**

| Scenario | Starting situation | Processing (real run) | Lines in the list |
|---|---|---|---|
| 1 | Open PO item, no inbound delivery (no `EKES` line with a delivery) | PO item changed with `BAPI_PO_CHANGE` | PO item (101) |
| 2.1 | Open PO item with an open inbound delivery item **with batch** | (1) batch master changed if it differs, (2) delivery item, (3) PO item | Batch (117), delivery item (119), PO item (101) |
| 2.2 | Open PO item with an open inbound delivery item **without batch** | (1) delivery item, (2) PO item | Delivery item (119), PO item (101) |
| 2.3 | Open PO item with an open inbound delivery item with an **existing batch** (material movement of the batch in the plant) | (1) batch master **not** changed, its valuation type is the reference, (2) delivery item set to it, (3) PO item set to it | Batch (134, orange), delivery item (119), PO item (101); *Reference* = `BATCH` |

In a test run (background) or as an online proposal, the same lines are shown
with messages 118, 120 and 102 and yellow *new* cells; nothing is saved. The
PO item line keeps scenario *2* (it may have deliveries of both kinds); the
batch and delivery lines show *2.1*, *2.2* or *2.3*. In scenario 2.3 the
*new* cells of the proposals are orange instead of yellow.

**Variants**

| # | Situation | Behaviour |
|---|---|---|
| V1 | All objects already have the new valuation type | Nothing changed, nothing listed (no change in the flow) – with option *Aligned flows*: all objects listed with 136; the PO item is counted as *already correct* (103) |
| V2 | PO item correct, delivery item (and / or batch) different | Delivery item (and batch) changed; the PO item is listed with 136 (display only) and counted as already correct |
| V3 | New batch already correct, delivery item different | Batch not changed, listed with 136; the delivery item (and PO item, if needed) changed |
| V4 | New batch different, delivery item already correct | Batch changed (117); the delivery item is listed with 136 |
| V5 | One PO item with several inbound deliveries | Each delivery changed in its own call; the PO item is changed only when all its open delivery items are aligned (D6) |
| V6 | One delivery with items of several PO items (same or different POs) | All items of the delivery changed in one call: all or none (D5). On error, every PO item concerned is not changed (121) |
| V7 | Several items of one PO | All items to change go into one `BAPI_PO_CHANGE` call: all or none. An item blocked by its delivery (121) or in error (D2) is left out of the call; the other items are still changed |
| V8 | Same batch on several delivery items | Batch checked and changed once; the result applies to all these delivery items |
| V9 | Batch split on the delivery (main item with sub-items) | Only the sub-items (with the batches) are processed; the main item is not changed and not listed |
| V10 | Delivery item with goods receipt (`WBSTA = C`) next to open ones | The received delivery item is ignored; the open ones are processed. If all delivery items are received, the PO item is changed alone (no blocking) |
| V11 | PO item with a goods receipt (`EKET-WEMNG > 0`), option *Items with goods receipt* off | Not selected: neither the PO item nor its deliveries and batches are changed or listed |
| V12 | As V11, option on | Listed only (warning 130, yellow light) with old / new valuation type and the last GR material document; never changed. Online: a selection containing such a row is refused (131) |
| V13 | Existing batch, delivery item and PO item already have its valuation type | Batch line 134 (orange), delivery item and PO item with 136; nothing changed |
| V14 | Existing batch, table value differs from the batch | The table value is ignored; delivery item and PO item get the batch value |
| V15 | One PO item with an existing batch and a new batch (same or another delivery) | The new batch is changed to the valuation type of the existing batch (117, *Reference* = `BATCH`, orange proposal); delivery items and PO item get it as well |
| V16 | Existing batch, no table entry for the year (or fiscal year not determined) | No error: the batch value is used (D11) |
| V17 | Batch shared by several PO items, listed in the flow of one of them | The batch is listed once, in the flow of the first PO item; it is not repeated with 136 in the other flows |
| V18 | PO item in error (D2: 100, 106, 107, 132, 133) | Only the PO item line E; its deliveries and batches are not listed (no target valuation type) |

**Error scenarios**

| # | Situation | Result |
|---|---|---|
| E1 | Fiscal year of the run date not determined for the company code | PO item line E (100); item and its deliveries / batches not processed |
| E2 | No active table entry for plant / material type / fiscal year (not for 2.3, see V16) | PO item line E (107); item and its deliveries / batches not processed |
| E3 | Table value (or 2.3: batch value) without own valuation record (`MBEW`, or flagged for deletion) | PO item line E (106); item and its deliveries / batches not processed. Checked even if the PO item is already correct |
| E4 | Batch master not found (`MCHA`) | Batch line E (122); delivery item E (124); PO item E (121) |
| E5 | Batch change refused by SAP (e.g. stock on the batch) | Batch line E (BAPI message); delivery item E (124); PO item E (121) |
| E6 | Delivery change fails (`WS_DELIVERY_UPDATE_2`) | All changed items of this delivery E (SAP message, or 125); their PO items E (121). Batches already changed stay changed |
| E7 | `BAPI_PO_CHANGE` returns an error (e.g. PO locked) | All items of this PO in the call E (BAPI message); deliveries and batches already changed stay changed |
| E8 | Change committed, but the valuation type read back differs | Line E (129). For a delivery item, its PO item is not changed (121) |
| E9 | PO item already correct, but one of its delivery items not aligned (E4 – E8) | PO item line E (121), although its own valuation type is right |
| E10 | Existing batch without valuation type in the batch master | PO item line E (132, *Reference* `BATCH`); item and its deliveries / batches not processed |
| E11 | Two existing batches of one PO item with different valuation types | PO item line E (133, both batches and values); item and its deliveries / batches not processed |

The program does not roll back objects already committed (batch before
delivery, delivery before PO). After an error, the run can be repeated: the
objects already aligned are not changed again (D7).

**Online posting scenarios** (D9)

| # | Selection | Result |
|---|---|---|
| P1 | Batch line, its delivery line and the PO line | Posted in the order batch → delivery → PO; all green, *Posted* ticked; message 128 |
| P2 | Batch line only | Batch posted; the delivery and PO lines stay open proposals |
| P3 | Delivery line only, batch not yet aligned | Delivery line E (124), not posted; can be posted again after the batch |
| P4 | Delivery line only, batch already aligned (earlier posting or V3) | Delivery item posted |
| P5 | PO line only, an open delivery item not aligned | PO line E (121), not posted; can be posted again after the delivery |
| P6 | PO line of scenario 1 | PO item posted |
| P7 | Lines already posted, or error lines of the simulation (e.g. E1 – E4, E7) | Not postable; if nothing else is selected: message 127 |
| P8 | Selection containing a line of V12 | Refused as a whole (131), nothing posted |
| P9 | *No* in the confirmation popup | Nothing posted |
| P10 | Batch line of an existing batch (134, no status light) | Not selectable: SALV cannot disable single rows, so on *Post* the line is removed from the selection (shown deselected) and never posted; alone: message 127. The delivery line can be posted directly – the batch already has the valuation type |
| P11 | Lines with 136 (already correct) | Ignored when posting; alone: message 127. SALV cannot block single rows, so they can be selected but are never posted |

Between the proposal and the posting, only the dependencies (batch, open
delivery items) are read again from the database; the proposal itself is not
recalculated.

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
| `S_VBELN` | `SELECT-OPTIONS FOR likp-vbeln` (`TABLES likp`), block `B01` |
| `P_GR` | `PARAMETERS AS CHECKBOX`, default off, block `B01` |
| `P_ALIGN` | `PARAMETERS AS CHECKBOX`, default off, block `B01` |
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
| `FILTER_BY_DELIVERY` | Only if `S_VBELN` is filled: keeps the PO items with an `EKES` line whose delivery is in `S_VBELN` |
| `SELECT_DELIVERIES` | Open inbound delivery items (`EKES` → `LIPS`/`LIKP`, `VBTYP = '7'`, `WBSTA <> 'C'`; batch split: sub-items only); sets the scenario. |
| `DETERMINE` | Fiscal year, valuation type and checks for one PO item (D2); with `BWTAR_REF` the batch value instead of the table (D11). Sets the log field `SOURCE` (`TABLE` / `BATCH`) |
| `READ_BATCHES` | Batch masters of all delivery items (`MCHA`: found, `BWTAR`) and material movements (`MSEG` for material, plant, batch – in S/4HANA read from `MATDOC`) in buffer `MT_BATCH_BUFFER` (fields `FOUND`, `BWTAR`, `USED`) |
| `SET_BATCH_REFERENCE` | Per PO item: valuation type of its existing batches in `BWTAR_REF` (batch in `REF_CHARG`), or error 132 / 133 in `REF_ERROR` |
| `IS_BATCH_USED` | Existing batch flag from the buffer (scenario 2.3 on the delivery line) |
| `ALIGN_DELIVERIES` / `ALIGN_BATCH` | Scenario 2 per delivery: batches first (once per batch – buffer field `DONE`), then `CHANGE_DELIVERY`. Existing batch: no change, info line 134 |
| `CHANGE_BATCH` | `BAPI_BATCH_CHANGE` (`VAL_TYPE`), commit or rollback |
| `CHANGE_DELIVERY` | `WS_DELIVERY_UPDATE_2` for all items of one delivery (`VBPOK-BWTAR`, batch passed again), commit; then `LE_DELIVERY_REFRESH_BUFFER` |
| `BLOCK_ITEM` | Marks the PO item as blocked by a delivery item not aligned (D6) |
| `LIST_UNCHANGED` | After all changes: for each PO item not in error with at least one line in `MT_LOG`, adds lines 136 (`MSGTY = I`, log field `NOCHANGE`) for the PO item, its open delivery items and their batches that are not in `MT_LOG` and already have the target valuation type (a batch only once over all flows). Not marked `TODO`, so never posted |
| `UPDATE_PURCHASE_ORDERS` / `CHANGE_PO` | `BAPI_PO_CHANGE` per PO (`VAL_TYPE`, `TESTRUN`, `NO_MESSAGING`), commit or rollback |
| `GET_FISCAL_YEAR` | `FI_PERIOD_DETERMINE` for the run date, buffered per company code |
| `GET_VALTYPE_FROM_TABLE` / `READ_VALTYPE` | Lookup order R4, buffered |
| `VALTYPE_EXISTS` | Valuation record check, buffered |
| `DISPLAY_LOG` / `BUILD_OUTPUT` / `SET_COLUMN_TEXT` | ALV output (`CL_SALV_TABLE`): output table `MT_OUT` built from the log `MT_LOG` (each line keeps its `MT_LOG` line in the technical column `LOGIDX`), sorted in the program by `EBELN`, object (batch, delivery, PO item – hidden column `RANK`) and `EBELP` and in the ALV by `EBELN` (grouped, with underline) and the hidden column `SEQ` (`EBELP` is no ALV sort column, otherwise repeated item numbers would be suppressed), status light in the exception column `LIGHT` (from `MSGTY`: E/A red, W yellow, S green, I none), cell colours in `T_COLOR` (`COL_TOTAL` yellow, `COL_GROUP` orange – *new* cell of a proposal with `SOURCE = BATCH`, `BAT_BWTAR_OLD` / `BAT_BWTAR_NEW` for message 134 – `COL_POSITIVE` green when the change was read back from the database – log field `VERIFIED`, set in `CHANGE_BATCH`, `CHANGE_DELIVERY`, `CHANGE_PO`) |
| `ON_ADDED_FUNCTION` | Online: handler of function `POST`; removes batch lines of an existing batch (`BAT_USED`) from the selection (`SET_SELECTED_ROWS`), posts the selected rows, rebuilds `MT_OUT`, refreshes the ALV |
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

   Then add messages 117 to 134 and 136 with the placeholders of 1.5 (134
   and 136 are used as type I; 135 already exists, do not change it).
10. **Report** – SE38, create executable program `ZPTP_VALTYPE_DOCSALIGN`,
    paste [ZPTP_VALTYPE_DOCSALIGN.abap](ZPTP_VALTYPE_DOCSALIGN.abap).
11. **GUI status** – SE41 (or SE80): copy status `STANDARD_FULLSCREEN` of
    program `SAPLSLVC_FULLSCREEN` to program `ZPTP_VALTYPE_DOCSALIGN`, status
    `ZSALV_POST`; add function code `POST` (text *Post selected*, with an
    icon) to the application toolbar; activate.
12. **Text elements** – selection texts: `S_WERKS` Plant, `S_EBELN` Purchase
    order, `S_VBELN` Inbound delivery, `P_GR` Items with goods receipt, `P_ALIGN` Aligned flows, `P_BGD` Background, `P_ONL` Online (post row by row), `P_TEST` Test
    run. Text symbols: `B01` *Selection*, `B02` *Run mode*, `T05` – `T08`,
    `T11` – `T46` (ALV headings and confirmation popup): create them from the
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
| D-T18 | As D-T3, batch without any material movement (new batch) | Same result as D-T3 (scenario 2.1, *Reference* `TABLE`) |
| D-T19 | Delivery item with a batch that has a material movement in the plant (e.g. GR of another PO); batch valuation type differs from the table, test run off | Batch master unchanged (line 134, orange); delivery item (119) and PO item (101) changed to the batch valuation type; scenario 2.3, *Reference* `BATCH` |
| D-T20 | As D-T19, online mode | Batch line with *Bat VT old* / *new* orange, no status light; selected and *Post*: deselected, not posted; delivery and PO proposals with orange *new* cells; after posting green |
| D-T21 | As D-T19, delivery item and PO item already have the batch value | Only the batch line 134; nothing changed |
| D-T22 | PO item with two existing batches with different valuation types | PO item error 133; nothing changed for the item |
| D-T23 | PO item with an existing and a new batch | New batch changed to the existing batch's valuation type (117), then delivery items and PO item |
| D-T24 | Existing batch, no table entry for the fiscal year | No error 107; batch value used |
| D-T25 | PO item already correct, its delivery item different (scenario 2.2) | Delivery item line (119 / 120) and PO item line 136 without light; in background the PO item is not changed; online the 136 line is not posted (127 if selected alone) |
| D-T26 | Batch already correct, delivery item and PO item different (scenario 2.1) | Batch line 136, delivery item and PO item changed |
| D-T27 | All objects of the flow already correct | Nothing listed |
| D-T28 | Batch lines of a new and of an existing batch | Checkbox *Batch with movement* empty for the new batch, ticked for the existing one; empty on delivery and PO lines |
| D-T29 | Option *Aligned flows*; flow where PO item, delivery item and batch already have the table value | All three listed with 136, no light, no colour; nothing changed (background) or posted (online, 127 if selected alone) |
| D-T30 | As D-T29, option off | Flow not listed |
| D-T31 | Inbound delivery range with one delivery of a PO item that has two open deliveries | PO item selected; both deliveries processed and listed |
| D-T32 | Inbound delivery range, PO item without inbound delivery | Not selected |

---

# Part 5 – Transport

| Request | Content |
|---|---|
| Workbench | Table `ZPTP_301_VALTYPE`, function group `ZPTP_301_VALTYPE`, message class `ZPTP_SPLIT_VAL`, class `ZCL_IM_MM_PO_SPLIT_VAL`, enhancement implementation `ZMM_PO_SPLIT_VAL_IMPL`, report `ZPTP_VALTYPE_DOCSALIGN` (with text elements and GUI status `ZSALV_POST`) |
| Customizing | SM30 entries of `ZPTP_301_VALTYPE` (client-specific – transport or maintain in each client and system) |

Import order: table and message class → class → enhancement implementation →
report (or everything on one request). Variants and background jobs are not
transported; create them in each system.
