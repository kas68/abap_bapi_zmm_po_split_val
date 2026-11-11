# Functional Specification
## Valuation type for split-valuated materials in purchasing

| | |
|---|---|
| Area | MM – Purchasing / Inventory valuation |
| Objects | BAdI implementation `ZCL_IM_MM_PO_SPLIT_VAL` (enhancement `ZMM_PO_SPLIT_VAL_IMPL`, BAdI `ME_PROCESS_PO_CUST`)<br>Report `ZPTP_VALTYPE_DOCSALIGN` |
| Customizing table | `ZPTP_301_VALTYPE` |
| Message class | `ZPTP_SPLIT_VAL` (numbers 100 and above) |
| Author | kas68 |
| Version | 1.0 |
| Date | 2026-11-10 |
| Related document | [SPECIFICATION.md](SPECIFICATION.md) – full functional and technical specification, setup and transport |

---

## 1. Business background

Some materials use **split valuation**: the stock of one material in one
plant is valued separately per *valuation type* (for example by origin,
quality or year). For these materials, each purchase order item must carry a
valuation type. If it is missing, the goods receipt fails.

Choosing the valuation type by hand slows buyers down and leads to mistakes.
The business wants the right value set automatically, based on the plant,
the material type and the year. The business maintains these rules in a
custom table.

The solution has two parts:

| Part | Object | What it does |
|---|---|---|
| A | BAdI implementation `ZCL_IM_MM_PO_SPLIT_VAL` | Sets the valuation type on purchase order items when a buyer creates or changes the PO. |
| B | Report `ZPTP_VALTYPE_DOCSALIGN` | Corrects the valuation type of **existing** open PO items, of their open inbound deliveries and of the batches on these deliveries. For example, at the start of a new fiscal year, before the goods receipt. |

---

## 2. Scope

**In scope**

- PO items created or changed in ME21N / ME22N, and through the purchase
  order BAPIs (`BAPI_PO_CREATE1`, `BAPI_PO_CHANGE`).
- Materials that are split-valuated in the valuation area of the plant.
- Bulk alignment of open PO items, their open inbound delivery items and the
  batches on these deliveries (report).

**Out of scope**

- Items without a material (services, text items) and deleted items.
- Tax code and tax jurisdiction. The SAP Tax Service implementation of the
  same BAdI handles these, and it runs side by side with this one.
- Special logic for stock transport orders and account-assigned items. They
  are handled like stock items (see open point O1).
- PO items that already have a goods receipt. The valuation type is fixed by
  the first goods receipt, so the report never changes these items.
- Outbound deliveries, production orders and reservations. The batch master
  of open production orders is covered by a separate development,
  `ZPTP_PROD_BATCH_VALTYPE`.

---

## 3. Determination table `ZPTP_301_VALTYPE`

The business maintains this table in **SM30**. It is client-specific
customizing, recorded on a customizing request.

| Field | Meaning |
|---|---|
| Plant | Plant of the PO item. *Blank* = all plants. |
| Material type | Material type of the material (`MARA-MTART`). *Blank* = all material types. |
| Year | Fiscal year of the company code (see 4.3 and 5.4). |
| Valuation type | Valuation type to use. |
| Active | Only entries with *Active* = X are used. |

### 3.1 Lookup order

Only active entries for the year are read. The **first match wins**:

1. Plant + material type
2. Plant + blank material type (plant default)
3. Blank plant + material type (material type default)
4. Blank plant + blank material type (global default)

### 3.2 Example

| Plant | Mat. type | Year | Val. type | Active | Result |
|---|---|---|---|---|---|
| 1000 | ROH | 2026 | NEW | X | Raw materials in plant 1000 |
| 1000 | *(blank)* | 2026 | STD | X | All other material types in plant 1000 |
| *(blank)* | HALB | 2026 | OWN | X | Semi-finished products in every other plant |
| *(blank)* | *(blank)* | 2026 | STD | X | Everything else |

A PO item in plant 2000 for a raw material (ROH) dated 2026 gets **STD**.
There is no line for 2000 + ROH, none for 2000 + blank and none for
blank + ROH, so the global default applies.

### 3.3 Maintenance rules

- New lines are needed for **every new year**. Without them, the BAdI leaves
  the field empty and the report reports error 107.
- For each material that uses the valuation type, the valuation type must
  also exist in the material master (accounting view, valuation record per
  valuation type). If it is missing or flagged for deletion, the value is
  not used (warning or error 106).
- A table change takes effect with the next PO that is opened. A PO already
  open in ME21N / ME22N keeps the values it has already read.

---

## 4. Part A – Automatic valuation type on the purchase order (BAdI)

### 4.1 Trigger

The logic runs each time SAP checks a PO item: on *Enter*, *Check* and
*Save* in ME21N / ME22N, and in the purchase order BAPIs. It only acts on
items that have a plant and a material and that are not deleted.

### 4.2 Process flow

```
PO item checked
  │
  ├─ no material / no plant / deleted ............... nothing
  │
  ├─ valuation type already filled?
  │     ├─ new item, first check (R6) ............... determine again
  │     └─ otherwise ................................ keep the value (R1)
  │
  ├─ read ZPTP_301_VALTYPE (plant, material type, year of PO date)
  │     └─ no entry ................................. field unchanged
  │                                                   (optional warning 107)
  ├─ material split-valuated in the plant? ── no ... nothing
  │
  ├─ valuation record exists for this value? ── no .. warning 106,
  │                                                   field unchanged
  └─ set the valuation type on the item
```

### 4.3 Business rules

| # | Rule |
|---|---|
| R1 | **The user's entry wins.** The valuation type is only proposed when the field is empty. A value entered by the buyer is kept. |
| R2 | **Year** = year of the PO document date, as the fiscal year of the item's company code. If the fiscal year cannot be determined, the calendar year is used. |
| R3 | **Lookup** in `ZPTP_301_VALTYPE` in the order of 3.1, active entries only. |
| R4 | **No table entry**: the field stays as it is. By default no message is shown. |
| R5 | **Split valuation**: the value is only set for materials that are split-valuated in the plant's valuation area. |
| R6 | **New items are determined again.** For a new item (new PO, or new item added in ME22N), the valuation type is determined from the table on its first check, even if it is already filled. This covers values copied from a reference PO or from another item, such as a last year's value. A value typed before the first *Enter*, or passed through a BAPI, is replaced as well. Any later change by the buyer is kept. No message is shown when the value is replaced. |
| R7 | **Copied value kept.** If R6 finds no usable table value, the copied value stays. If that value has no valid valuation record, warning 106 is shown. |
| R8 | **Valuation record**: the value from the table must exist for the material in the valuation area and must not be flagged for deletion. Otherwise warning 106 is shown and the field is not changed. |
| R9 | Each warning appears **once** per item and content. It does not repeat on every *Enter*. |
| R10 | Messages are **warnings**. The PO can always be saved. |

### 4.4 Settings

The settings are fixed in the program. A change needs a development and a
transport.

| Setting | Current value | Effect when switched on |
|---|---|---|
| Override user entry | Off | The table value replaces a value entered by the user, but never on items with PO history (goods receipt, invoice) or flagged *delivery completed*. **Must stay off** while report `ZPTP_VALTYPE_DOCSALIGN` is in use. Otherwise the BAdI would overwrite the value the report sets. |
| Warn if no table entry | Off | Warning 107 when no table entry is found. See limitation L3 first. |
| Use fiscal year | On | Off = the table year is read as a calendar year. |
| Determine again on new items | On | Off = a copied value is treated like a user entry (rule R6 off). |

### 4.5 Examples

| # | Situation | Result |
|---|---|---|
| A1 | ME21N, split-valuated ROH material in plant 1000, valuation type empty | **NEW** proposed (table line 1000 / ROH) |
| A2 | Buyer types *STD* on an existing item | *STD* kept |
| A3 | ME21N with reference to a 2025 PO whose items carry the 2025 value | Items get the 2026 table value, no message |
| A4 | As A3, then the buyer changes the value and presses *Enter* | Buyer's value kept |
| A5 | Table value *NEW* has no valuation record for the material | Warning 106, field unchanged |
| A6 | Material not split-valuated | Nothing happens |
| A7 | No table line for the year | Field stays empty, goods receipt will ask for it |

---

## 5. Part B – Document alignment report `ZPTP_VALTYPE_DOCSALIGN`

### 5.1 Purpose

The BAdI only acts when a PO is entered or changed. Documents created before
the go-live, or before a new year's table lines existed, may carry an old
valuation type. The same applies to the inbound deliveries and batches
created from them.

The report brings these documents in line with the table, for the **fiscal
year of the run date**. It handles the whole document flow of a PO item:
**PO item → open inbound delivery items → batches on these delivery items**.

Typical use: at the start of a new fiscal year, before the first goods
receipts of the year, or after a table correction.

### 5.2 Selection screen

**Frame *Selection***

| Field | Default | Meaning |
|---|---|---|
| Plant | `8Q01` | Plant of the PO item |
| Purchase order | – | PO number |
| Inbound delivery | – | Selects the PO items that have an inbound delivery in this range. The whole flow of these PO items is processed, including their other open deliveries outside the range, so that the PO item stays aligned with all its deliveries. |
| Items with goods receipt | Off | Also **lists** PO items that already have a goods receipt (partial or full), with the number of the last goods receipt document. These items are shown with warning 130 and are **never changed**. |
| Aligned flows | Off | Also lists flows where every object already has the right valuation type (information 136, display only). |

**Frame *Run mode***

| Field | Default | Meaning |
|---|---|---|
| Background | – | All changes in one run. Can be scheduled as a job. |
| Online | **Selected** | The program simulates first, then shows the proposed changes. The user selects rows and posts them. Can't run in background (error 126). |
| Test run | On | Background mode only: nothing is saved, the list shows what would change. Greyed out in online mode. |

### 5.3 Selected PO items

A PO item is processed when **all** of these apply:

- standard purchase order (document category *F*), PO header and item not
  deleted;
- item not flagged *delivery completed* and not a return item;
- quantity still open on at least one schedule line;
- **no goods receipt yet** on any schedule line (partially received items
  are not changed);
- material split-valuated in the plant's valuation area.

### 5.4 Target valuation type

| # | Rule |
|---|---|
| D1 | The year is the **fiscal year of the run date** in the company code of the PO item. This is not the PO date, unlike the BAdI. If it cannot be determined: error 100. |
| D2 | The valuation type is read from `ZPTP_301_VALTYPE` in the order of 3.1. No entry: error 107. |
| D3 | **Existing batch takes priority.** If a delivery item of the PO item carries a batch that already has material movements in the plant (an *existing batch*), the batch's valuation type is used instead of the table value. The table is not read, so errors 100 and 107 do not apply. A batch with stock can't be revalued, so the PO and delivery must follow the batch. |
| D4 | The target value must have its own valuation record for the material (not flagged for deletion). Otherwise: error 106. |
| D5 | A PO item in error (100, 106, 107, 132, 133) is not processed, and neither are its deliveries and batches. |

### 5.5 Scenarios

| Scenario | Starting situation | What the report changes, in this order |
|---|---|---|
| **1** | Open PO item, no inbound delivery | PO item |
| **2.1** | Open PO item with an open inbound delivery item **with a new batch** (no material movement yet) | 1. batch master (if different) 2. delivery item 3. PO item |
| **2.2** | Open PO item with an open inbound delivery item **without batch** | 1. delivery item 2. PO item |
| **2.3** | Open PO item with an open inbound delivery item with an **existing batch** | Batch master **not** changed, its value is the reference. 1. delivery item 2. PO item |

Only delivery items **without goods receipt** are processed. Received
delivery items are ignored. If all deliveries of a PO item are received, the
PO item is changed on its own.

### 5.6 Processing rules

| # | Rule |
|---|---|
| D6 | **Order**: all batches first, then all delivery items, then the PO items. A delivery item with a batch is changed only after its batch is aligned (otherwise error 124). A PO item is changed only when **all** its open delivery items are aligned (otherwise error 121). This way the PO item always ends up with the valuation type of its deliveries. |
| D7 | **All or nothing per document**: all items of one delivery are changed together, and so are all items of one PO. If the change fails, none of the items of that document is changed. |
| D8 | A batch used on several delivery items is checked and changed **once**. |
| D9 | With a batch split, only the sub-items (which carry the batches) are processed. The main item is not. |
| D10 | Objects that already have the right valuation type are **never changed**. |
| D11 | The PO is changed **without output** to the vendor. No new PO printout or EDI message is sent. |
| D12 | Each real change is **read back** from the database after it is saved. Only a confirmed change counts as successful. Otherwise the line shows error 129. |
| D13 | **Two existing batches with different valuation types** on the same PO item: error 133. An **existing batch without a valuation type**: error 132. In both cases the item is not processed. |
| D14 | If a PO item has both an existing and a new batch, the new batch is changed to the existing batch's valuation type. The PO item then has one valuation type for all its goods receipts. |
| D15 | **No rollback across documents.** A batch or delivery already saved stays changed even if a later step fails (for example, the PO is locked). The run can simply be repeated: already aligned objects are skipped (D10). |

### 5.7 Run modes

**Background**

- *Test run on*: everything is checked and simulated, nothing is saved.
- *Test run off*: all changes are made in one run.
- In a job, the summaries go to the job log and the list goes to the spool.

**Online**

1. The program runs a simulation, the same as a test run.
2. The list shows each change found as a **proposal**.
3. The user selects rows and chooses **Post**, then confirms the popup.
4. The selected rows are posted in the order batches → delivery items →
   PO items, whatever order the user selected them in.
5. Before posting, the dependencies are read again from the database. A
   delivery item needs its batch already aligned (124). A PO item needs all
   its open delivery items already aligned (121). The user can therefore
   post a batch first and its delivery later, or select both together.
6. Message 128 shows how many rows were posted and how many failed. The list
   is refreshed. Posted rows are ticked in column *Posted*.
7. Failed rows can be posted again. Errors found in the simulation can't be
   posted.

Online posting restrictions:

| Selection | Result |
|---|---|
| Nothing postable selected (only posted rows, error rows, information rows) | Message 127, nothing posted |
| Selection contains an item with goods receipt (130) | Whole selection refused (131), nothing posted |
| Existing-batch line (134) or *already correct* line (136) | Ignored when posting, never posted |
| *No* in the confirmation popup | Nothing posted |

### 5.8 Output list (ALV)

One line per object (batch, delivery item, PO item), sorted and grouped by
purchase order. Within a PO the order is batches, then delivery items, then
PO items.

**Main columns**: plant, status light, PO, object, PO item, delivery,
delivery item, material document (only with *Items with goods receipt*),
material, batch, material type, fiscal year, old / new valuation type for
the PO, delivery and batch, *Batch with movement*, reference, scenario,
message, message type and *Posted* (online only).

| Column | Meaning |
|---|---|
| PO VT old / new | Filled on PO item lines |
| Delivery VT old / new | Filled on delivery item lines |
| Batch VT old / new | Filled on batch lines |
| Batch with movement | Ticked on batch lines of an existing batch (scenario 2.3) |
| Reference | `TABLE` = value from `ZPTP_301_VALTYPE`; `BATCH` = value from an existing batch |

**Status light**: green = success or proposal, yellow = warning (item with
goods receipt), red = error, none = information only (134, 136).

**Cell colours on the *new* value**

Only the *new* cell of the object's own column pair is coloured (PO,
delivery or batch). The one exception is the existing-batch line (134).

| Colour | ALV colour | Meaning |
|---|---|---|
| Yellow | `COL_TOTAL` | Change that would be made (test run or online proposal), value from the table |
| Orange | `COL_GROUP` | As yellow, but the value comes from an existing batch (reference `BATCH`). On the existing-batch line itself (134), both *Batch VT old* and *Batch VT new* are orange. |
| Green | `COL_POSITIVE` | Real change (background run or posted online), read back and confirmed on the database. Stays green even when the value came from an existing batch. |
| None | – | Error lines, warning lines with goods receipt (130) and *already correct* lines (136) |

**Flow display**: once one object of a flow is listed (change, proposal,
error or 134), the other objects of the same flow that need no change are
listed too, with information 136. This shows the user the whole flow. If no
object of a flow needs a change, the flow is not listed, unless *Aligned
flows* is selected.

**Summaries** at the end of each run:
- 123 – delivery items selected / changed / batches changed / errors
- 103 – PO items selected / changed / already correct / errors

**Traceability**: there is no separate application log. Changes appear in
the standard change documents of the PO, the delivery and the batch.

### 5.9 Example

PO 4500001234 item 10, plant 8Q01, material type ROH. The table gives
**NEW** for 2026. The PO item has **OLD**. Inbound delivery 180000567
item 10 carries the new batch B001 with **OLD**.

Online mode, simulation:

| Object | Scen. | PO VT old → new | Dlv VT old → new | Batch VT old → new | Message |
|---|---|---|---|---|---|
| Batch | 2.1 | | | OLD → **NEW** (yellow) | 118 – would change |
| Delivery | 2.1 | | OLD → **NEW** (yellow) | | 120 – would change |
| PO item | 2 | OLD → **NEW** (yellow) | | | 102 – would change |

The user selects all three rows and posts. The batch, the delivery and the
PO are changed in that order, all three *new* cells turn green, and message
128 reports *3 posted, 0 errors*.

If batch B001 already had a goods movement and carried **OLD**, the batch
line would show 134 (*valuation type OLD kept*, orange). The delivery item
and PO item would stay on **OLD** and be listed with 136, and the table
value NEW would be ignored.

### 5.10 Error situations

| # | Situation | Result |
|---|---|---|
| E1 | Fiscal year not determined | PO item error 100; flow not processed |
| E2 | No active table entry (not for scenario 2.3) | PO item error 107; flow not processed |
| E3 | Target value without valuation record | PO item error 106; flow not processed |
| E4 | Batch master not found | Batch error 122 → delivery item 124 → PO item 121 |
| E5 | Batch change refused by SAP (for example, stock on the batch) | Batch error (SAP message) → delivery item 124 → PO item 121 |
| E6 | Delivery change fails | All changed items of the delivery in error (SAP message or 125) → their PO items 121 |
| E7 | PO change fails (for example, PO locked) | All items of that PO in the call in error (SAP message) |
| E8 | Change saved but not found on the database | Error 129; for a delivery item, its PO item 121 |
| E9 | Existing batch without valuation type | PO item error 132 |
| E10 | Existing batches of one PO item disagree | PO item error 133 |

**Restart**: fix the cause (table line, valuation record, lock) and run the
report again. Objects already aligned are skipped.

---

## 6. Messages

Message class `ZPTP_SPLIT_VAL`. Numbers 000–099 belong to other programs.
Numbers 105, 108–116 and 135 are reserved and must not be reused.

| No. | Text (meaning) | Used by |
|---|---|---|
| 100 | Fiscal year not determined for company code &1 and date &2 | Report |
| 101 | Valuation type changed from &1 to &2 | Report – PO item |
| 102 | Test run: valuation type would change from &1 to &2 | Report – PO item |
| 103 | &1 items selected, &2 changed, &3 already correct, &4 errors | Report – summary |
| 104 | No open purchase order items selected | Report |
| 106 | Valuation type &1 not defined for material &2 in plant &3 | BAdI (W), report (E) |
| 107 | No valuation type maintained in ZPTP_301_VALTYPE for &1 / &2 / &3 | BAdI (W, only if activated), report (E) |
| 117 | Batch valuation type changed from &1 to &2 | Report |
| 118 | Test run: batch valuation type would change from &1 to &2 | Report |
| 119 | Delivery item valuation type changed from &1 to &2 | Report |
| 120 | Test run: delivery item valuation type would change from &1 to &2 | Report |
| 121 | PO item not changed – delivery &1 item &2 not aligned | Report |
| 122 | Batch &1 not found for material &2 in plant &3 | Report |
| 123 | Deliveries: &1 selected, &2 changed, &3 batches changed, &4 errors | Report – summary |
| 124 | Batch &1 not aligned – delivery item not changed | Report |
| 125 | Delivery &1 not changed (no detailed message returned) | Report |
| 126 | Mode *Online* cannot run in background | Report |
| 127 | Select at least one proposed change not yet posted | Report – online |
| 128 | &1 posted, &2 errors | Report – online |
| 129 | Change not confirmed on the database: expected &1, found &2 | Report |
| 130 (W) | Goods receipt posted (&1) – item not changed | Report – option *Items with goods receipt* |
| 131 | &1 selected rows have a goods receipt and cannot be posted | Report – online |
| 132 | Existing batch &1 without valuation type | Report |
| 133 | Batch &1 (&2) and batch &3 (&4) differ | Report |
| 134 (I) | Batch &1 used: valuation type &2 kept | Report |
| 136 (I) | Valuation type &1 already correct | Report |

---

## 7. Assumptions, open points and limitations

### 7.1 Open points (business decision needed)

| # | Point |
|---|---|
| O1 | Stock transport orders and account-assigned items are treated like stock items. |
| O2 | A batch counts as *existing* when it has any material document item in the same plant, reversals included. Movements of the same batch number in other plants are not considered. |
| O3 | When a PO item has both an existing and a new batch, the new batch takes the existing batch's valuation type, not the table value (D14). |
| O4 | Online mode does not add dependent rows automatically. A delivery item with a batch needs the batch row posted first or in the same selection, and a PO item needs its delivery rows. |
| O5 | The BAdI uses the year of the **PO date**, while the report uses the fiscal year of the **run date**. An open PO dated in the old year, aligned by the report, gets the new year's value. This is intended for year-end alignment. |

### 7.2 Known limitations

| # | Limitation |
|---|---|
| L1 | Warning 106 in ME21N / ME22N is not linked to the valuation type field, so a double-click does not jump to the field. |
| L2 | SAP gives no marker for copied values. Rule R6 therefore also replaces a value typed or passed by BAPI before the first check of a new item. |
| L3 | Warning 107, if activated, would also show for materials that are not split-valuated. Fix this before switching the setting on. |
| L4 | Changing the PO date to another year, or changing material or plant, on a new item after its first check does not trigger a new determination. A filled value is then kept. |
| L5 | An item with an empty valuation type is filled even if it is flagged delivery completed. |
| L6 | In the report's online mode, single rows can't be locked. Information rows (134, 136) can be selected, but they are never posted. |

---

## 8. Functional test scenarios

**Prerequisite**: a material split-valuated in the test plant (MM03,
accounting view: valuation category set, valuation types with their own
valuation records) and table lines for the current year.

**BAdI**

| # | Test | Expected |
|---|---|---|
| T1 | Material type has its own line, field empty | Value from the material-type line |
| T2 | Only a plant default exists | Value from the plant default |
| T3 | User enters a value | User's value kept |
| T4 | Material not split-valuated | Nothing happens |
| T5 | Table value without valuation record | Warning 106 once, field unchanged |
| T6 | ME21N with reference to a last-year PO | Current-year value, no message |
| T7 | As T6, user then changes the value | User's value kept |
| T8 | ME22N: copy an item | New item gets the table value; original item unchanged |
| T9 | `BAPI_PO_CREATE1` with a valuation type passed | Table value replaces it (R6) |
| T10 | Item with tax code / jurisdiction | Tax fields unchanged |

**Report**

| # | Test | Expected |
|---|---|---|
| T11 | Background test run, scenario 1 | Message 102, yellow cell, PO unchanged |
| T12 | As T11, test run off | Message 101, green cell, PO change document |
| T13 | Scenario 2.1, test run off | Batch 117, delivery 119, PO 101, in that order; all green |
| T14 | As T13, batch has stock and SAP refuses the change | Batch error, delivery 124, PO 121; nothing else changed |
| T15 | Scenario 2.3, batch value differs from the table | Batch 134 (orange), delivery and PO set to the batch value, reference `BATCH` |
| T16 | Two existing batches with different values | Error 133, nothing changed |
| T17 | PO item already correct, delivery item different | Delivery changed; PO line 136, not changed |
| T18 | All objects already correct | Nothing listed; with *Aligned flows*, all listed with 136 |
| T19 | Item with goods receipt, option off / on | Off: not listed; on: warning 130 with GR document, not postable (131) |
| T20 | Delivery range covering one of two deliveries of a PO item | Both deliveries processed |
| T21 | Online: post batch and delivery rows | Both green, *Posted* ticked, message 128 |
| T22 | Online: post delivery row only, batch not aligned | Error 124; can be posted after the batch |
| T23 | Online: *Post* without a postable row, or *No* in the popup | Message 127 / nothing posted |
| T24 | Online mode scheduled as a job | Error 126 |
| T25 | Background job | Summaries 123 and 103 in the job log, list in the spool |

---

## 9. Glossary

| Term | Meaning |
|---|---|
| Split valuation | Valuation of one material's stock in separate parts, one per valuation type |
| Valuation type | Key of one part of a split-valuated material's stock (`BWTAR`) |
| Valuation record | Accounting data of the material for one valuation type in a valuation area (`MBEW`) |
| Existing batch | Batch with at least one material movement in the plant; its valuation type can no longer be changed |
| New batch | Batch created (for example, on the inbound delivery) without any material movement yet |
| Flow | A PO item, its open inbound delivery items and the batches on these items |
| Open PO item | Item of a standard PO, not deleted, not delivery completed, not a return, with open quantity and no goods receipt |
