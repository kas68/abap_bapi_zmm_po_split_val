# Functional and Technical Specification
## Default valuation type on purchase order items (ZMM_PO_SPLIT_VAL)

| | |
|---|---|
| Area | MM – Purchasing / Inventory valuation |
| Enhancement | BAdI `ME_PROCESS_PO_CUST` |
| Enhancement implementation | `ZMM_PO_SPLIT_VAL_IMPL` |
| Implementing class | `ZCL_IM_MM_PO_SPLIT_VAL` ([source](ZCL_IM_MM_PO_SPLIT_VAL.abap)) |
| Mass update report | `ZMM_PO_SPLIT_VAL_UPDATE` ([source](ZMM_PO_SPLIT_VAL_UPDATE.abap)) |
| Author | kas68 |
| Date | 2026-09-29 |
| Last update | 2026-10-02 – mass update report |

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
- Mass update of open purchase order items by report
  `ZMM_PO_SPLIT_VAL_UPDATE`, mainly as a background job (see 1.8).

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
| R4 | Lookup order: first plant + material type + year; if not found, plant + empty material type + year (plant default). |
| R5 | No table entry: the field stays as it is (empty, or a value kept under R1, R2 or R10). Optionally a warning is shown. |
| R6 | The material must be split-valuated in the plant's valuation area; otherwise the valuation type is not set. Warning 024 may still be shown when activated (see 2.7). |
| R7 | The valuation type must exist for the material in the valuation area (not flagged for deletion); otherwise a warning is shown and the field stays empty. |
| R8 | Each warning is shown once per item and content. |
| R9 | New items (PO not yet saved, or new item added in ME22N): on the first processing, a filled valuation type is determined again from the table (setting, on by default). This covers values copied from a reference PO or another item. A value typed by the user before the first Enter, or passed through a BAPI, is overwritten too; a later change by the user is kept. No message is shown when the value is replaced. |
| R10 | If R9 cannot determine a value (no table entry, or the table value has no valuation record) the copied value is kept; if the material is split-valuated and the copied value's own valuation record is missing or flagged for deletion, warning 023 is shown. |

## 1.4 Maintenance of determination data

Table `ZPTP_PO_VALTYPE`, maintained in SM30 by the business (client-specific,
customizing request).

| Plant | Mat. type | Year | Val. type | Meaning |
|---|---|---|---|---|
| 1000 | ROH | 2026 | NEW | Raw materials in plant 1000, POs dated 2026 |
| 1000 | HALB | 2026 | OWN | Semi-finished products in plant 1000, POs dated 2026 |
| 1000 | *(empty)* | 2026 | STD | All other material types in plant 1000, POs dated 2026 |

A new line per plant (and material type, where needed) must be maintained
for each new year.

## 1.5 Messages

Message class `ZPTP_SPLIT_VAL`. In the BAdI the messages are type **W**
(warning – the PO can still be saved). In the report they are written to the
output list (1.8).

| No. | Text | When |
|---|---|---|
| 023 | Valuation type &1 not defined for material &2 in plant &3 | R7 – valuation record missing; R10 – copied value kept without valuation record; report: U5 |
| 024 | No valuation type maintained in ZPTP_PO_VALTYPE for &1 / &2 / &3 | R5 – no table entry (only if activated); report: U5 |
| 100 | Fiscal year not determined for company code &1 and date &2 | Report: U3 |
| 101 | Valuation type changed from &1 to &2 | Report: item changed |
| 102 | Test run: valuation type would change from &1 to &2 | Report: test run |
| 103 | &1 items selected, &2 changed, &3 already correct, &4 errors | Report: summary at the end of the run |
| 104 | No open purchase order items selected | Report: nothing selected |
| 105 | Enter a key date for option 'Key date' | Report: option "Key date" without a date |

## 1.6 Settings

| Setting | Default | Effect |
|---|---|---|
| Override user entry | Off | On = rule R2 applies. Must stay **Off** while report `ZMM_PO_SPLIT_VAL_UPDATE` is used (see 1.8, U7). |
| Warn if no table entry | Off | On = message 024 is shown |
| Use fiscal year | On | On = the table holds fiscal years of the company code; Off = calendar years |
| Determine again on new items | On | On = rule R9 applies; Off = a copied value counts as a user entry |

Settings are constants in the class (see 2.4); a change requires a transport.

## 1.7 Assumptions and open points

- Stock transport orders and account-assigned items are treated like stock
  items. To be confirmed by the business.
- Warning 023 is not yet linked to the valuation type field on screen (see 2.7).
- Warning 024, if activated, is also shown for materials without split
  valuation (see 2.7). To be fixed before the setting is switched on.
- Report: items with an invoice but no goods receipt are not updated (U2).
  To be confirmed by the business.

## 1.8 Mass update report `ZMM_PO_SPLIT_VAL_UPDATE`

**Purpose** – The BAdI sets the valuation type when the PO is entered, based on
the PO document date. The report sets it again on open items, based on the
fiscal year of a key date – for example at the start of a new fiscal year, so
that open items receive the valuation type of the new year before goods
receipt. It is meant to run mainly as a background job.

**Selection screen**

| Field | Type | Meaning |
|---|---|---|
| Plant | Select-option | `EKPO-WERKS` |
| Purchase order | Select-option | `EKPO-EBELN` |
| Material | Select-option | `EKPO-MATNR` |
| Run date of the program | Radio button (default) | Key date = date of the run |
| Key date | Radio button + date field | Key date = date entered (field ready for input only with this option) |
| Test run | Checkbox, default **on** | No update; shows what would change |

All select-options empty = all open POs of the system.

**Rules**

| # | Rule |
|---|---|
| U1 | Only standard purchase orders; PO and item not deleted; item not delivery completed. |
| U2 | Only items without any PO history (goods receipt, invoice, …) and without an inbound delivery. |
| U3 | The year is the fiscal year of the key date in the item's company code. If it cannot be determined, the item is an error (no fallback to the calendar year, unlike R3). |
| U4 | The valuation type is read from `ZPTP_PO_VALTYPE` with the lookup order R4, for the item's plant and material type. |
| U5 | Only split-valuated materials. No table entry (024) or no valuation record for the new valuation type (023): the item is an error and is not changed. |
| U6 | The valuation type is replaced whatever its current value, including a value entered by the user. Items that already have the right value are not changed. |
| U7 | All items of one PO are changed together: if the change fails (e.g. PO locked in ME22N), no item of that PO is changed and all are listed as errors. No output (print, EDI) is sent to the vendor for the change. |
| U8 | Test run: the change is fully checked but not saved. |

**Output**

- Summary message 103. Online: status bar; background: job log (SM37).
- List of changed items (or items that would change in a test run) and errors:
  message type, PO, item, plant, material, material type, fiscal year, old and
  new valuation type, message. Online: ALV with sort, filter and export;
  background: spool of the job.
- Not listed: items already correct (only counted), items not selected (U1, U2,
  material not split-valuated – not counted either). No list if there is
  nothing to show; message 104 if no item is selected.
- No application log (SLG1). The changes are traceable in the PO change
  documents (ME23N → Environment → Item changes), with the job user. Test
  runs and errors leave no trace after the job log and spool are deleted.

**Background job** – Option "Run date of the program" uses the actual date of
each run; a variant with this option needs no dynamic date. With option "Key
date", the date saved in the variant is used.

---

# Part 2 – Technical specification

## 2.1 Object list

| Object | Type | Transaction | Name |
|---|---|---|---|
| BAdI definition | New BAdI (migrated classic BAdI), multiple use | SE18 | `ME_PROCESS_PO_CUST` |
| Enhancement implementation | Enhancement implementation | SE19 | `ZMM_PO_SPLIT_VAL_IMPL` |
| BAdI implementation | BAdI implementation | SE19 | `ZMM_PO_SPLIT_VAL_IMPL` |
| Implementing class | Global class | SE24 | `ZCL_IM_MM_PO_SPLIT_VAL` |
| Custom table | Transparent table, delivery class C | SE11 | `ZPTP_PO_VALTYPE` |
| Maintenance function group | Table maintenance generator | SE11 / SE80 | `ZPTP_PO_VALTYPE` |
| Message class | Message class | SE91 | `ZPTP_SPLIT_VAL` |
| Mass update report | Executable program | SE38 | `ZMM_PO_SPLIT_VAL_UPDATE` |

## 2.2 Table `ZPTP_PO_VALTYPE`

| Field | Key | Data element | Check table | Remark |
|---|---|---|---|---|
| MANDT | X | MANDT | | |
| WERKS | X | WERKS_D | T001W | |
| MTART | X | MTART | T134 | Empty = plant default. Foreign key without **Check required**. |
| GJAHR | X | GJAHR | | Calendar or fiscal year (setting) |
| BWTAR | | BWTAR_D | T149D | |

Technical settings: data class APPL2, size category 0, buffering not allowed
(the class buffers the data per PO).

Table maintenance: authorization group `&NC&` (or project-specific), function
group `ZPTP_PO_VALTYPE`, one-step, standard recording routine.

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
| `C_WARN_IF_MISSING` | `abap_false` | Warn if no table entry (message 024) |
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
| `READ_VALTYPE` | private | Single read of `ZPTP_PO_VALTYPE` (buffered) |
| `GET_BWKEY` | private | Valuation area of the plant |
| `IS_SPLIT_VALUATED` | private | Split valuation check (buffered) |
| `VALTYPE_EXISTS` | private | Valuation record check (buffered) |
| `HAS_FOLLOW_ON_DOCS` | private | PO history check; skipped for new POs |
| `GET_ITEM_STATE` | private | First processing of the item and new-item flag (buffered per item) |
| `WARN_IF_VALTYPE_INVALID` | private | Warning 023 for a kept copied value (R10) |
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
6. Read the valuation type with `GET_VALTYPE_FROM_TABLE`. If empty: message 024
   (if activated); on re-determination, `WARN_IF_VALTYPE_INVALID` (R10); exit.
7. Exit if the value equals the current `BWTAR`. This prevents endless
   re-processing after `SET_DATA`.
8. Exit if the material is not split-valuated (`IS_SPLIT_VALUATED`).
9. If `VALTYPE_EXISTS` returns false: message 023; on re-determination,
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

- Warning 023 has no field link: the `mmpur_metafield` line in `PROCESS_ITEM`
  is commented out until the `MMMFD` constant for `BWTAR` is confirmed.
- Changes to `ZPTP_PO_VALTYPE` during an open PO become visible with the next PO.
- SAP leaves no copy marker on a PO item, so R9 cannot tell a copied value from
  one typed by the user or passed through a BAPI before the first processing.
- R9 does not cover a change of `BEDAT` into another year after the first
  processing of the item.
- R9 does not cover a change of material or plant on a new item after its
  first processing: a filled valuation type is then kept like a user entry.
- The table lookup (step 6) runs before the split-valuation check (step 8).
  With `C_WARN_IF_MISSING` on, warning 024 is therefore also shown for
  materials that are not split-valuated, in a plant / year without a table
  line. No impact with the default setting (off); before switching it on, the
  split-valuation check must move before the table lookup.
- The protection of R2 (delivery completed, PO history) applies only to items
  whose valuation type is already filled. An item with an empty valuation
  type is filled even if it is flagged delivery completed.
- Message variables are passed in internal format: in warning 023, a numeric
  material number (&2) is shown with leading zeros.
- Comments must stay inside class sections or methods. Comments outside them
  cause the error *"The class contains unknown comments which can't be stored"*.

## 2.8 Report `ZMM_PO_SPLIT_VAL_UPDATE`

Executable program with message class `ZPTP_SPLIT_VAL` (`MESSAGE-ID`) and one
local class `LCL_APP`. The table lookup, the valuation record check and their
buffers are copies of the BAdI class logic (the class methods are private).

**Selection screen**

| Name | Definition |
|---|---|
| `S_WERKS` | `SELECT-OPTIONS FOR ekpo-werks` |
| `S_EBELN` | `SELECT-OPTIONS FOR ekpo-ebeln` |
| `S_MATNR` | `SELECT-OPTIONS FOR ekpo-matnr` |
| `P_RUN` | Radio button group `DATE`, default, `USER-COMMAND date` |
| `P_KEY` | Radio button group `DATE` |
| `P_DATE` | `TYPE sy-datum`, `MODIF ID key` |
| `P_TEST` | Checkbox, default `abap_true` |

Events:
- `AT SELECTION-SCREEN OUTPUT` – `P_DATE` ready for input only when `P_KEY` is
  set.
- `AT SELECTION-SCREEN` – error 105 if `P_KEY` is set and `P_DATE` is empty, on
  execution (`ONLI`), job scheduling (`SJOB`) or in background only.
- `START-OF-SELECTION` – `NEW lcl_app( )->run( )`.

**Methods of `LCL_APP`**

| Method | Purpose |
|---|---|
| `RUN` | Main logic (below) |
| `SELECT_ITEMS` | Selection of open items (one SELECT) |
| `DETERMINE` | Fiscal year, valuation type and checks for one item; returns a log line |
| `CHANGE_PO` | `BAPI_PO_CHANGE` for all items to change of one PO, commit or rollback |
| `GET_FISCAL_YEAR` | `FI_PERIOD_DETERMINE` for the key date, buffered per company code |
| `GET_VALTYPE_FROM_TABLE` / `READ_VALTYPE` | Lookup order R4, buffered |
| `VALTYPE_EXISTS` | Valuation record check, buffered |
| `DISPLAY_LOG` / `SET_COLUMN_TEXT` | ALV output (`CL_SALV_TABLE`) |

**Selection (`SELECT_ITEMS`)**

`EKKO` ⋈ `EKPO` ⋈ `MARA` (material type) ⋈ `T001W` (valuation area) ⋈ `MBEW`
(header record, `BWTAR = space`), with:

| Condition | Meaning |
|---|---|
| `EKKO-BSTYP = 'F'`, `EKKO-LOEKZ = space` | Standard PO, not deleted |
| `EKPO-LOEKZ = space`, `EKPO-ELIKZ = space` | Item not deleted, not delivery completed |
| `MBEW-BWTTY <> space` | Material split-valuated in the valuation area |
| `NOT EXISTS EKBE` for `EBELN` / `EBELP` | No PO history |
| `NOT EXISTS EKES` with `VBELN <> space` | No inbound delivery |
| Select-options | Plant, PO, material |

**Processing logic (`RUN`)**

1. Key date = `SY-DATLO` (`P_RUN`) or `P_DATE` (`P_KEY`).
2. Select the items; message 104 and exit if none.
3. Per PO (`LOOP AT ... GROUP BY ebeln`), per item (`DETERMINE`):
   - fiscal year of the key date (`FI_PERIOD_DETERMINE`, item `BUKRS`);
     error 100 if not determined;
   - valuation type from `ZPTP_PO_VALTYPE` (R4); error 024 if none;
   - same as the current `BWTAR`: counted as already correct, not listed;
   - no valuation record in `MBEW` (`LVORM = space`): error 023;
   - otherwise the item is collected for the change.
4. `CHANGE_PO` for the collected items of the PO: `BAPI_PO_CHANGE` with
   `POITEM-VAL_TYPE` / `POITEMX-VAL_TYPE`, `TESTRUN = P_TEST`,
   `NO_MESSAGING = abap_true`.
   - Any `E` / `A` message: `BAPI_TRANSACTION_ROLLBACK`; all items of the PO get
     type E and the text of the first `E` / `A` message.
   - Otherwise: `BAPI_TRANSACTION_COMMIT` with `WAIT` (rollback in test run);
     items get type S and message 101 (102 in test run).
5. Summary message 103 (type S – job log in background).
6. ALV list of changed items and errors (spool in background).

**Interaction with the BAdI** – `BAPI_PO_CHANGE` runs the BAdI. The item is
saved and its `BWTAR` filled, so with `C_OVERRIDE_USER_ENTRY = abap_false` the
BAdI keeps the value passed by the report. With the setting on, the BAdI would
replace it with the value for the PO document date.

**Known limitations**

- No fallback to the calendar year when `FI_PERIOD_DETERMINE` fails (U3).
- Any PO history excludes the item, not only goods receipts (U2).
- An error on one item (e.g. BAPI check) blocks all items of the same PO (U7);
  the message shown on each item is the first error of the PO.
- No application log (SLG1); job log and spool follow the system's deletion
  jobs.
- Empty select-options select all open POs of the system: the SELECT reads the
  whole of `EKPO` (acceptable in background).
- Items deleted, delivery completed, with history or not split-valuated are
  not counted in the summary.

---

# Part 3 – Implementation

1. **Table** – create `ZPTP_PO_VALTYPE` as in 2.2 and activate. If the table
   already exists without `MTART`: add the field, activate, adjust the database
   in SE14 (existing rows become plant defaults).
2. **Maintenance view** – SE11 → Utilities → Table Maintenance Generator, with
   the settings in 2.2. After table changes: **Change** → **New field/sec. table
   in structure**.
3. **Message class** – create `ZPTP_SPLIT_VAL` with messages 023 and 024 (1.5).
   Keep the placeholder order:
   - 023: &1 = valuation type, &2 = material, &3 = plant
   - 024: &1 = plant, &2 = material type, &3 = year
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
8. **Data** – maintain `ZPTP_PO_VALTYPE` in SM30 (1.4).
9. **Report messages** – add messages 100 to 105 to `ZPTP_SPLIT_VAL` (1.5).
   Keep the placeholder order:
   - 100: &1 = company code, &2 = date
   - 101, 102: &1 = old valuation type, &2 = new valuation type
   - 103: &1 = selected, &2 = changed, &3 = already correct, &4 = errors
10. **Report** – SE38, create executable program `ZMM_PO_SPLIT_VAL_UPDATE`,
    paste [ZMM_PO_SPLIT_VAL_UPDATE.abap](ZMM_PO_SPLIT_VAL_UPDATE.abap), check
    syntax and activate.
11. **Text elements** – selection texts: `S_WERKS` Plant, `S_EBELN` Purchase
    order, `S_MATNR` Material, `P_RUN` Run date of the program, `P_KEY` Key
    date, `P_DATE` Key date for fiscal year, `P_TEST` Test run (or *Dictionary
    ref.* for the select-options). Text symbols `T01` to `T04` (ALV column
    headings): create them from the source by double-click.
12. **Background job** – create a variant (test run off, date option as
    required) and schedule the job in SM36 with this variant. Run it first with
    test run on and check the spool.

---

# Part 4 – Test cases

Prerequisite: a material split-valuated in the test plant (MM03, Accounting 1:
valuation category set, valuation types with their own accounting records).

| # | Case | Expected |
|---|---|---|
| T1 | Material type has its own table line, valuation type field empty | Valuation type from the material-type line |
| T2 | Material type without its own line, plant default exists | Valuation type from the plant default line |
| T3 | No line at all (warning setting on) | Warning 024 once; field stays empty |
| T4 | User enters a valuation type (override off) | User's value is kept |
| T5 | Material without split valuation | Nothing happens |
| T6 | Table value has no valuation record for the material | Warning 023 once; field stays empty |
| T7 | PO document date in another year | Line for that year is used |
| T8 | ME22N on an item with a goods receipt (override on) | Valuation type isn't changed |
| T9 | Item with tax code / jurisdiction | Tax fields unchanged |
| T10 | ME21N with reference to a PO of the previous year (valuation type filled) | Valuation type of the current year from the table, no message |
| T11 | As T10, then the user changes the valuation type and presses Enter | User's value is kept |
| T12 | As T10, no table entry for the current year; copied valuation type flagged for deletion in `MBEW` | Copied value kept; warning 023 once |
| T13 | ME22N: copy an item within a saved PO | New item gets the table value; the original item is unchanged |
| T14 | `BAPI_PO_CREATE1` with `BWTAR` filled and a table entry | Table value replaces the BAPI value (R9) |

Debugging: breakpoint in `IF_EX_ME_PROCESS_PO_CUST~PROCESS_ITEM`.

**Report `ZMM_PO_SPLIT_VAL_UPDATE`**

| # | Case | Expected |
|---|---|---|
| U-T1 | Test run, open item with another valuation type in the table for the key date's fiscal year | Listed with type S and message 102; PO unchanged |
| U-T2 | As U-T1, test run off | Message 101; valuation type changed; change document in ME23N; no new output to the vendor |
| U-T3 | Item already with the right valuation type | Not listed; counted as already correct |
| U-T4 | Item with goods receipt, invoice or inbound delivery | Not selected |
| U-T5 | Item deleted or delivery completed; material not split-valuated | Not selected |
| U-T6 | No table entry for the fiscal year | Error 024; item unchanged |
| U-T7 | Table value without valuation record for the material | Error 023; item unchanged |
| U-T8 | PO open in ME22N by another user during the run | All items of the PO listed as errors with the lock message; PO unchanged |
| U-T9 | Option "Key date" with a date in another fiscal year | Valuation type of that fiscal year |
| U-T10 | Option "Key date" with empty date | Error 105 on execution; switching the radio buttons gives no error |
| U-T11 | Option "Run date" in a background job | Fiscal year of the job's run date |
| U-T12 | Background job | Summary 103 in the job log, list in the spool |
| U-T13 | User-entered valuation type differing from the table | Replaced by the table value (U6) |

---

# Part 5 – Transport

| Request | Content |
|---|---|
| Workbench | Table `ZPTP_PO_VALTYPE`, function group `ZPTP_PO_VALTYPE`, message class `ZPTP_SPLIT_VAL`, class `ZCL_IM_MM_PO_SPLIT_VAL`, enhancement implementation `ZMM_PO_SPLIT_VAL_IMPL`, report `ZMM_PO_SPLIT_VAL_UPDATE` (with text elements) |
| Customizing | SM30 entries of `ZPTP_PO_VALTYPE` (client-specific – transport or maintain in each client and system) |

Import order: table and message class → class → enhancement implementation →
report (or everything on one request). Variants and background jobs are not
transported; create them in each system.
