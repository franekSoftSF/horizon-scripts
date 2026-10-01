# Nowy złoty obraz: automatyzacja vCenter i OSDCloud

> Wersja angielska: [../vcenter-osdcloud.md](../vcenter-osdcloud.md)
> Powiązane: [image-lifecycle.md](image-lifecycle.md) §2 / §2a (kroki budowy), §7 (które wydanie Windows dla której wersji Horizon).

Wszystko uruchamiasz na **komputerze administratora**, w przygotowanym `C:\install` (po Configure i Download), z menu
START albo bezpośrednio. Wynik to VM w **trybie audytu** z `C:\install` i otwartym menu. Dalej robisz kroki 4–7
z menu (Update, Optimize, kontrola gotowości, Generalize).

```
 komputer administratora                    vCenter                       VM złotego obrazu
 ─────────────────────────────────────      ───────────────────────       ──────────────────────────────
 B  New-BuildMedia.ps1          ─┐
    (ISO Windows + VDI-Build.iso) ├─ ISO ─▶ C  Invoke-GoldenVm -New ─▶ instalacja → tryb audytu → menu
 O  New-BuildMedia -OSDCloud    ─┘          (wysłanie, utworzenie, start) 4 Update · 5 Optimize · 6 kontrola
                                            Snapshot (pre-generalize) ◀─ 7 Generalize → agenty → Seal
                                            R  Invoke-GoldenVm -Release ◀ wyłączenie
                                            Horizon Console: Push Image
```

## 1. Dwa sposoby instalacji Windows

| | **B – Instalator** (`New-BuildMedia.ps1`) | **O – OSDCloud** (`New-BuildMedia.ps1 -Method OSDCloud`) |
|---|---|---|
| Źródło Windows | Twoje ISO (VLSC / centrum administracyjne Microsoft 365) na CD 1 | Pobierane z Microsoft w WinPE (`Start-OSDCloud`), najnowszy miesięczny ESD |
| Dodatkowy nośnik | `VDI-Build.iso` na CD 2 (autounattend.xml + C:\install) | Jedno ISO: WinPE + C:\install + plik odpowiedzi |
| Wymagania na komputerze administratora | brak (wbudowany IMAPI2) | **Windows ADK + dodatek WinPE**, moduł **OSD** (`Install-Module OSD`), PowerShell jako administrator |
| Wymagania na VM | – | **Dostęp do internetu** z sieci budowy (serwery pobierania Microsoft) |
| Klawisz przy starcie | „Press any key” – wysyła go `Invoke-GoldenVm` (kody USB) | brak (`OSDCloud_NoPrompt.iso`) |
| TPM | sprawdzanie pominięte w instalatorze (`-WithVtpm`, aby je zostawić) | DISM nakłada obraz – bez sprawdzania TPM |
| Język | musi pasować do ISO (`-UILanguage`) | dowolny z języków OSDCloud (pl-pl, en-us, de-de, fr-fr, ...) |
| Edycje | Enterprise, Education, Pro, Pro Education | Enterprise, Education, Pro (licencja zbiorcza) |
| Najlepsze dla | sieci odciętej / kontrolowanego ISO, dokładnej kompilacji | zawsze aktualnego obrazu, bez obsługi ISO |

Obie metody używają tego samego pliku odpowiedzi dla zainstalowanego Windows:
- nazwa komputera i strefa czasowa z `packages.json` Build;
- `PreventDeviceEncryption=1` i wyłączone automatyczne aktualizacje Store;
- **tryb audytu** (`Reseal Mode=Audit`);
- na końcu menu (`-AutoStart Menu`) albo `-Mode Update -AutoReboot` (`-AutoStart Update`).

Na żadnym nośniku nie ma hasła.

### Szczegóły OSDCloud
- Moduł OSD (github.com/OSDeploy/OSD, sprawdzony z wersją 26.9.30). Skrypt wykonuje kolejno:
  `New-OSDCloudTemplate` (jednorazowo), `New-OSDCloudWorkspace` (`C:\OSDCloud\VDI-ImageMaint`), `Edit-OSDCloudWinPE -CloudDriver VMware -StartOSDCloud
  "-OSName 'Windows 11 24H2 x64' -OSEdition Enterprise -OSLanguage pl-pl -OSActivation Volume -ZTI -SkipAutopilot -SkipODT -Restart"`,
  `New-OSDCloudISO`. Na koniec kopiuje `OSDCloud_NoPrompt.iso` jako `VDI-OSDCloud.iso` obok `C:\install`.
- `-Release` 24H2 / 25H2 / 26H2. Domyślnie `Windows.TargetRelease`, a gdy go brak, **24H2**: Horizon 2506 wspiera najwyżej 24H2.
- **`-ZTI` czyści dysk 0 bez pytania.** Uruchamiaj to ISO tylko w nowej VM złotego obrazu.
- Po nałożeniu Windows OSDCloud uruchamia `Media\OSDCloud\Config\Scripts\Shutdown\VDI-ImageMaint.ps1`. Ten skrypt kopiuje
  `install\` do `C:\install`, a plik odpowiedzi do `C:\Windows\Panther\unattend.xml`. Na VM OSDCloud nie tworzy
  partycji odzyskiwania.
- Po zmianie `C:\install` zbuduj nośnik ponownie: uruchom **O** jeszcze raz. Szablon i przestrzeń robocza zostają użyte ponownie.

## 2. vCenter (`Invoke-GoldenVm.ps1`, VMware PowerCLI)

Jednorazowo zainstaluj PowerCLI: `Install-Module VCF.PowerCLI -Scope CurrentUser` (albo `VMware.PowerCLI`). Skopiuj `vcenter.example.json`
do `vcenter.json` i uzupełnij:

| Pole | Znaczenie |
|---|---|
| `Server` | FQDN vCenter. Dane logowania: istniejąca sesja, SSO Windows albo pytanie (`-Credential`). Nigdy nie są zapisywane |
| `Cluster` / `VMHost` | Gdzie utworzyć VM (jedno z dwóch) |
| `Datastore`, `Folder`, `Network` | Dysk VM, folder VM, grupa portów (standardowa albo rozproszona) sieci budowy |
| `IsoDatastore`, `IsoFolder` | Dokąd wysłać ISO nośnika (domyślnie `Datastore`, `ISO/VDI-ImageMaint`) |
| `WindowsIso` | Tylko metoda B: `[datastore] folder/Win11_24H2_Polish_x64.iso` |
| `VM` | `Name`, `NumCpu`, `CoresPerSocket`, `MemoryGB`, `DiskGB` (thin), `GuestId` (`windows11_64Guest`) |

Akcje (menu **C** / **R** albo bezpośrednio skrypt):

| Akcja | Co robi |
|---|---|
| `-Action New [-Method Setup\|OSDCloud]` | Wysyła ISO nośnika i tworzy VM: gość Windows 11, **EFI + Secure Boot, bez vTPM**, **PVSCSI**, **VMXNET3**, dysk thin, bez stacji dyskietek, `devices.hotplug=FALSE`, kolejność startu CD → dysk. Podłącza napędy CD i włącza VM. Dla metody B przez 20 s wysyła Enter |
| `-Action Snapshot` | Snapshot `pre-generalize <data>` – przed krokiem 7 menu (Generalize) |
| `-Action Release` | VM musi być wyłączona (po `Seal -Shutdown`). Opróżnia napędy CD, usuwa vTPM, jeśli jest, i robi snapshot `Gold <data>`. Potem Horizon Console → pula → **Maintain → Schedule** (Push Image) z tym snapshotem |
| `-ValidateOnly` | Sprawdza `vcenter.json` i pokazuje plan, bez PowerCLI |

Każdy klon dostaje vTPM dzięki opcji puli („Add vTPM device to VMs”), a nie ze złotego obrazu (KB 85960).

## 3. Horizon Push Image (`Invoke-HorizonPushImage.ps1`, REST API)

Nie wymaga PowerCLI - używa REST API Horizon Server (Horizon 8 2206+). Ustawienia: sekcja `Horizon` w `vcenter.json`:

| Pole | Znaczenie |
|---|---|
| `Server` | FQDN Connection Servera (HTTPS). Logowanie: `-Credential` albo pytanie (`DOMENA\użytkownik`), nigdy nie zapisywane |
| `Pools` | Pule Instant Clone używające tego złotego obrazu, np. `["W11-Students", "W11-Staff"]` |
| `LogoffPolicy` | `WAIT_FOR_LOGOFF` (domyślnie) albo `FORCE_LOGOFF` |
| `StopOnFirstError` | `true` (domyślnie) – Push Image zatrzymuje się na pierwszej maszynie z błędem |

Złoty obraz to `VM.Name`, a vCenter to `Server`.

| Akcja | Wywołania REST |
|---|---|
| `-Action Push` (menu **P**, z `-Wait`) | `POST /rest/login` → `GET /monitor/v2/virtual-centers` → `GET /external/v1/datacenters`, `base-vms`, `base-snapshots` → dla każdej puli `GET /inventory/v2/desktop-pools/{id}` (zachowuje ustawienie vTPM puli) → `POST /inventory/v2/desktop-pools/{id}/action/schedule-push-image` → `POST /rest/logout` |
| `-Action Status` | stan obrazu w każdej puli (bieżący / oczekujący / operacja / błąd) |
| `-Action Cancel` | `POST /inventory/v1/desktop-pools/{id}/action/cancel-scheduled-push-image` (przed startem) |
| `-Action List` | snapshoty złotego obrazu widziane przez Horizon |

- Snapshot: domyślnie najnowszy `Gold*` (tworzy go `Invoke-GoldenVm -Action Release`) albo `-SnapshotName`.
- `-StartTime` dla okna serwisowego (np. dziś 02:00), inaczej od razu. `-WhatIf` pokazuje JSON i niczego nie wysyła.
- **Wycofanie:** wypchnij poprzedni snapshot `Gold` (`-SnapshotName "Gold 2026-09-02 ..."`). Trzymaj 2–3 ostatnie snapshoty Gold.
- Certyfikat Connection Servera jest sprawdzany. `-SkipCertificateCheck` używaj tylko w labie.
## 4. Co przetestowano

- Testy Pester w `windows/tests/BuildMedia.Tests.ps1` obejmują:
  - wyszukiwanie obrazu i snapshotu, treść żądania Push Image i format wywołań REST (z atrapą API);
  - pliki odpowiedzi (obie metody);
  - zapis ISO metody B (PS 5.1 i pwsh 7, po zamontowaniu: UDF, komplet plików);
  - `-ValidateOnly` i ścieżki błędów.
- **Jeszcze nie testowano:**
  - Push Image na prawdziwym Connection Serverze;
  - budowy nośnika OSDCloud (wymaga ADK);
  - akcji vCenter (wymagają PowerCLI i vCenter);
  - instalacji na prawdziwej VM.

  Przetestuj to raz w labie i zapisz wynik w `status.md`.
