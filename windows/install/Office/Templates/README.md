# Office (ODT) configuration templates

Ready-made Office Deployment Tool configurations for shared, non-persistent VDI. All of them use
**Shared Computer Activation** (`SharedComputerLicensing=1`): on Instant Clones the users sign in to Office on
changing machines, so per-device activation does not work.

| File | License (ODT product) | Language |
|---|---|---|
| `O365ProPlusRetail-Shared_pl-pl.xml` | Microsoft 365 Apps for enterprise / education (E3/E5, A3/A5) | Polish |
| `O365ProPlusRetail-Shared_en-us.xml` | same | English |
| `O365ProPlusRetail-Shared_de-de.xml` | same | German |
| `O365ProPlusRetail-Shared_fr-fr.xml` | same | French |
| `O365ProPlusRetail-Shared_pl-pl_en-us.xml` | same | Polish + English (both full) |
| `O365BusinessRetail-Shared_*.xml` | Microsoft 365 Apps for business - **Shared Computer Activation needs Microsoft 365 Business Premium** | as above |

Common settings: 64-bit, channel `MonthlyEnterprise`, `Updates Enabled="FALSE"` (the image is updated by
VDI-ImageMaint), `FORCEAPPSHUTDOWN=TRUE`, `Display Level="None"`, excluded: Groove, Skype for Business (Lync),
OneDrive (installed per machine separately), Teams (new Teams = MSIX), Bing, Publisher (retired by Microsoft
in October 2026).

**How to use one:** in `packages.json`, entry `Office365`, set `"Config": "Templates\\<file>.xml"` - or run
`-Mode Configure` (step 2 offers the same languages and writes `Office\Configuration_x64.xml`). The tool checks
the file before installing (`-Mode Validate`, `PackageList`).

---

**PL:** Gotowe konfiguracje ODT dla współdzielonego, nietrwałego VDI. Wszystkie używają **Shared Computer
Activation**, bo na klonach Instant Clone użytkownicy logują się do Office na zmieniających się maszynach.
`O365BusinessRetail` z aktywacją współdzieloną wymaga licencji **Microsoft 365 Business Premium**.
Użycie: w `packages.json`, we wpisie `Office365`, ustaw `"Config": "Templates\\<plik>.xml"`, albo uruchom
`-Mode Configure` (krok 2 ma te same języki i zapisuje `Office\Configuration_x64.xml`).
