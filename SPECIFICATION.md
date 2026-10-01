# Functional and Technical Specification
## Default valuation type on purchase order items (ZMM_PO_SPLIT_VAL)

| | |
|---|---|
| Area | MM – Purchasing / Inventory valuation |
| Enhancement | BAdI `ME_PROCESS_PO_CUST` |
| Enhancement implementation | `ZMM_PO_SPLIT_VAL_IMPL` |
| Implementing class | `ZCL_IM_MM_PO_SPLIT_VAL` ([source](ZCL_IM_MM_PO_SPLIT_VAL.abap)) |
| Author | kas68 |
| Date | 2026-09-29 |

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
| R5 | No table entry: the field stays empty. Optionally a warning is shown. |
| R6 | The material must be split-valuated in the plant's valuation area; otherwise nothing happens. |
| R7 | The valuation type must exist for the material in the valuation area (not flagged for deletion); otherwise a warning is shown and the field stays empty. |
| R8 | Each warning is shown once per item and content. |
| R9 | New items (PO not yet saved, or new item added in ME22N): on the first processing, a filled valuation type is determined again from the table (setting, on by default). This covers values copied from a reference PO or another item. A value typed by the user before the first Enter, or passed through a BAPI, is overwritten too; a later change by the user is kept. No message is shown when the value is replaced. |
| R10 | If R9 cannot determine a value (no table entry, or the table value has no valuation record) the copied value is kept; if its own valuation record is missing or flagged for deletion, warning 023 is shown. |

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

Message class `ZPTP_SPLIT_VAL`, type **W** (warning – the PO can still be saved).

| No. | Text | When |
|---|---|---|
| 023 | Valuation type &1 not defined for material &2 in plant &3 | R7 – valuation record missing; R10 – copied value kept without valuation record |
| 024 | No valuation type maintained in ZPTP_PO_VALTYPE for &1 / &2 / &3 | R5 – no table entry (only if activated) |

## 1.6 Settings

| Setting | Default | Effect |
|---|---|---|
| Override user entry | Off | On = rule R2 applies |
| Warn if no table entry | Off | On = message 024 is shown |
| Use fiscal year | On | On = the table holds fiscal years of the company code; Off = calendar years |
| Determine again on new items | On | On = rule R9 applies; Off = a copied value counts as a user entry |

Settings are constants in the class (see 2.4); a change requires a transport.

## 1.7 Assumptions and open points

- Stock transport orders and account-assigned items are treated like stock
  items. To be confirmed by the business.
- Warning 023 is not yet linked to the valuation type field on screen (see 2.7).

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
- Comments must stay inside class sections or methods. Comments outside them
  cause the error *"The class contains unknown comments which can't be stored"*.

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

---

# Part 5 – Transport

| Request | Content |
|---|---|
| Workbench | Table `ZPTP_PO_VALTYPE`, function group `ZPTP_PO_VALTYPE`, message class `ZPTP_SPLIT_VAL`, class `ZCL_IM_MM_PO_SPLIT_VAL`, enhancement implementation `ZMM_PO_SPLIT_VAL_IMPL` |
| Customizing | SM30 entries of `ZPTP_PO_VALTYPE` (client-specific – transport or maintain in each client and system) |

Import order: table and message class → class → enhancement implementation
(or everything on one request).
