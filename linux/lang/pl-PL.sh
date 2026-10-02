# shellcheck shell=bash disable=SC2034,SC2154  # MSG is declared -A by load_lang
# VDI-ImageMaint for Linux - polska tabela komunikatów (drugi język).
# Te same klucze co en-US.sh; brakujący klucz = tekst angielski.

# --- common ---
MSG[start_banner]='VDI-ImageMaint dla Linuksa %s - tryb: %s, profil: %s, język: %s'
MSG[err_root]='Uruchom jako root (sudo).'
MSG[err_unexpected]='Nieoczekiwany błąd (kod %s) w linii %s: %s'
MSG[err_unknown_option]='Nieznana opcja: %s'
MSG[err_profile]='Nieznany profil "%s" (dozwolone: university, business).'
MSG[conf_missing]='Ustawienie %s jest puste lub ma wartość przykładową - ustaw je w %s'
MSG[prompt_yes_no]='%s [t/N]:'
MSG[installing_dep]='Instaluję wymagane narzędzie: %s'
MSG[unit_absent]='Jednostka %s nie jest zainstalowana - pominięto.'
MSG[unit_restore_failed]='Nie udało się ponownie włączyć %s.'
MSG[unit_restored]='Przywrócono %s (stan pierwotny: %s).'
MSG[file_unchanged]='Bez zmian: %s'
MSG[file_written]='Zapisano: %s'
MSG[file_restored]='Przywrócono: %s'
MSG[os_unsupported]='Wspierany system to Debian 12 (bookworm); wykryto: %s'
MSG[reboot_needed]='Przed kolejnym krokiem wymagany jest restart.'

# --- menu / usage ---
MSG[menu_title]='=== VDI-ImageMaint dla Linuksa %s (profil: %s) ==='
MSG[menu_prepare]='1. System bazowy: pakiety, MATE + LightDM, locale, czas'
MSG[menu_nfs]='3. Katalogi domowe NFSv4 + Kerberos (autofs)'
MSG[menu_agent]='4. Horizon Linux Agent (Instant Clone, offline join) - potem restart'
MSG[menu_optimize]='6. Optymalizacja VDI (odwracalna: optimize --revert)'
MSG[menu_check]='8. Kontrola gotowości (tylko odczyt)'
MSG[menu_seal]='9. Zamknięcie (Seal) przed snapshotem (blokada pakietów, cisza dla użytkowników)'
MSG[menu_update]='Co miesiąc: odblokuj, apt full-upgrade (potem ponownie Seal)'
MSG[menu_unlock]='Cofnij zamknięcie (Seal)'
MSG[menu_status]='Pokaż stan narzędzia'
MSG[menu_quit]='Wyjście'
MSG[menu_prompt]='Wybierz:'
MSG[menu_step_failed]='Krok "%s" nie zakończył się - zobacz log.'
MSG[usage_text]='Użycie: sudo %s <tryb> [opcje]

Budowa (raz):   prepare -> domain -> nfs -> agent -> restart -> recording -> apps -> optimize -> collab -> check -> seal
Istniejący obraz: adopt -> agent/recording/apps -> optimize -> collab -> check -> seal
Co miesiąc:     update --then-seal       Cofnięcie zamknięcia: unlock

Tryby:
  adopt      istniejący obraz: wykrycie, utworzenie vdi-imagemaint.conf, podgląd (diff), zachowanie kroków, zapis wersji agenta
  prepare    pakiety bazowe, MATE + LightDM, locale, klawiatura, strefa czasowa, NTP
  domain     krb5.conf, SSSD, realm join obrazu, sudo, True SSO / karta
  kerberos   bezpieczeństwo SSSD/Kerberos: bez automatycznej zmiany hasła komputera, czekanie na czas, odnawianie biletów
  nfs        katalogi domowe NFSv4 z Kerberosem (autofs, rpc.gssd, idmapd)
  agent      instalacja/aktualizacja agenta Horizon (z kontrolą wersji; zależności, sterownik USB VHCI, dźwięk), RunOnce
  usb        sam sterownik USB VHCI (przejęty obraz, bez reinstalacji agenta)
  recording  Horizon Recording Agent (tryb szablonu -t; pyta o hasło do serwera)
  apps       uruchamia apps/*.sh --install (np. Eclipse)
  optimize   strojenie VDI (usługi, dconf MATE, LightDM, journald, sysctl, I/O, polkit)
  collab     ustawienia Session Collaboration - pyta o każdą wartość (link UAG)
  check      kontrola gotowości tylko do odczytu (kod 1 przy błędach)
  seal       check + sprzątanie + blokada pakietów + cisza dla użytkowników, potem wyłączenie
  unlock     cofnięcie seal
  update     odblokowanie (jeśli zamknięty), apt full-upgrade, autoremove
  fido       test przekierowania FIDO2 w sesji na klonie
  status     wersja, profil, zapisane zmiany
  self-update  sprawdź GitHub teraz i zaktualizuj narzędzie (także przy AUTO_UPGRADE=no)

Opcje:
  --config PLIK   plik konfiguracji (domyślnie: vdi-imagemaint.conf obok narzędzia)
  --lang en-US|pl-PL
  --revert        z optimize: cofnij wszystkie optymalizacje
  --then-seal     z update: zamknij obraz, jeśli nie trzeba restartu
  --force         seal mimo błędów kontroli; ponowne wykonanie kroku; reinstalacja lub obniżenie wersji agentów
  -y, --yes       odpowiadaj "tak" na pytania
  --no-upgrade    pomiń automatyczną aktualizację narzędzia w tym uruchomieniu
'

# --- prepare ---
MSG[step_prepare]='PREPARE - system bazowy'
MSG[ask_continue_unsupported]='Ten system nie jest wspierany. Kontynuować mimo to?'
MSG[locale_set]='Locale: %s, domyślne %s, klawiatura %s'
MSG[time_set]='Strefa czasowa %s, NTP: %s'
MSG[desktop_install]='Instaluję pulpit: %s'
MSG[edge_install]='Instaluję Microsoft Edge (packages.microsoft.com)'
MSG[prepare_done]='System bazowy gotowy.'

# --- DNS ---
MSG[dns_srv_missing]='Nie znaleziono rekordu DNS %s - sprawdź serwery DNS tej maszyny.'

# --- nfs ---
MSG[step_nfs]='NFS - katalogi domowe (NFSv4 + Kerberos)'
MSG[nfs_disabled]='NFS_ENABLE nie jest "yes" - pominięto.'
MSG[nfs_no_keytab]='Brak /etc/krb5.keytab na obrazie wzorcowym - katalogi NFS można przetestować dopiero na klonie (keytab tworzy offline join Horizon).'
MSG[nfs_server_resolves]='Serwer NFS %s rozwiązuje się w DNS.'
MSG[nfs_server_unresolved]='Serwer NFS %s nie rozwiązuje się w DNS.'
MSG[nfs_done]='Katalogi domowe: %s montowane na żądanie pod %s (sec=%s).'

# --- agent ---
MSG[step_agent]='AGENT - Horizon Linux Agent'
MSG[agent_archive_missing]='Brak instalatora Horizon Linux Agent (.tar.gz lub rozpakowany katalog) w: %s'
MSG[agent_installing]='Instaluję %s z parametrami: %s'
MSG[agent_installer_missing]='Nie znaleziono install_viewagent.sh w %s.'
MSG[agent_install_failed]='Instalacja Horizon Linux Agent nie powiodła się.'
MSG[agent_conf_missing]='Nie znaleziono katalogu konfiguracji agenta (/etc/omnissa ani /etc/vmware).'
MSG[agent_configured]='Agent skonfigurowany dla Instant Clone (OfflineJoinDomain, SSO, RunOnceScript): %s'
MSG[agent_done]='Horizon Linux Agent %s gotowy.'

# --- optimize ---
MSG[step_optimize]='OPTIMIZE - strojenie VDI'
MSG[autostart_disabled]='Wyłączono autostart: %s'
MSG[optimize_done]='Optymalizacja zakończona (cofnięcie: optimize --revert).'
MSG[step_optimize_revert]='OPTIMIZE --revert - cofanie optymalizacji'
MSG[optimize_reverted]='Optymalizacje cofnięte.'

# --- update ---
MSG[step_update]='UPDATE - pakiety'
MSG[update_unlocking]='Obraz jest zamknięty - najpierw odblokowuję.'
MSG[update_new_kernel]='Nowe jądro %s -> %s: sprawdź, czy agent Horizon je wspiera.'
MSG[update_done]='Pakiety zaktualizowane.'
MSG[update_seal_after_reboot]='Uruchom ponownie, potem wykonaj: seal'

# --- seal / unlock ---
MSG[step_seal]='SEAL - przygotowanie do snapshotu'
MSG[seal_blocked]='Seal przerwany: popraw wyniki ERR powyżej (lub użyj --force).'
MSG[seal_forced]='Seal kontynuowany mimo błędów kontroli (--force).'
MSG[seal_ssh_keys_removed]='Usunięto klucze hosta SSH - każdy klon wygeneruje własne.'
MSG[seal_cleaning]='Czyszczenie cache, logów, biletów i dzierżaw DHCP.'
MSG[seal_cleaned]='Sprzątanie zakończone.'
MSG[seal_done]='Obraz zamknięty. Wyłącz maszynę i wykonaj snapshot dla puli Instant Clone.'
MSG[ask_poweroff]='Wyłączyć teraz?'
MSG[step_unlock]='UNLOCK - cofanie seal'
MSG[unlock_not_sealed]='Obraz nie jest zamknięty - przywracam to, co zapisano.'
MSG[unlock_done]='Seal cofnięty - obraz można zmieniać.'

# --- check / status ---
MSG[step_check]='CHECK - gotowość'
MSG[chk_os_ok]='Debian 12.'
MSG[chk_os_bad]='System to nie Debian 12 - nietestowane.'
MSG[chk_reboot_pending]='Oczekuje restart (działa jądro %s, zainstalowane %s).'
MSG[chk_reboot_none]='Restart nie jest wymagany.'
MSG[chk_dpkg_broken]='dpkg zgłasza uszkodzone lub niedoinstalowane pakiety (dpkg --audit).'
MSG[chk_dpkg_ok]='Baza pakietów spójna.'
MSG[chk_agent_ok]='Usługa agenta Horizon %s włączona.'
MSG[chk_agent_missing]='Brak usługi agenta Horizon lub jest wyłączona.'
MSG[chk_agent_conf_missing]='Nie znaleziono viewagent-custom.conf.'
MSG[chk_offlinejoin_ok]='OfflineJoinDomain=sssd.'
MSG[chk_offlinejoin_bad]='W %s nie ustawiono OfflineJoinDomain=sssd.'
MSG[chk_runonce_ok]='RunOnceScript %s istnieje.'
MSG[chk_runonce_bad]='RunOnceScript "%s" nie istnieje lub nie jest wykonywalny - uruchom adopt (istniejący obraz) albo agent; seal usuwa klucze SSH i na nim polega.'
MSG[chk_sssd_ok]='SSSD działa.'
MSG[chk_sssd_bad]='SSSD nie działa.'
MSG[chk_time_ok]='Czas zsynchronizowany (NTP).'
MSG[chk_time_bad]='Czas niezsynchronizowany - Kerberos nie działa przy różnicy powyżej 5 minut.'
MSG[chk_dns_ok]='Rekordy DNS SRV dla %s znalezione.'
MSG[chk_desktop_ok]='LightDM + sesja MATE.'
MSG[chk_desktop_bad]='LightDM nie jest menedżerem logowania albo brak sesji MATE.'
MSG[chk_nfs_ok]='Katalogi domowe NFS skonfigurowane pod %s.'
MSG[chk_nfs_bad]='Niekompletna konfiguracja NFS (autofs, /etc/auto.vdi-home lub Domain w idmapd).'
MSG[chk_vmtools_ok]='open-vm-tools działa.'
MSG[chk_vmtools_bad]='open-vm-tools nie działa.'
MSG[chk_held]='Wstrzymane pakiety: %s'
MSG[chk_local_users]='Istnieją konta lokalne (zostaw tylko konto administratora budowy): %s'
MSG[chk_disk_low]='Tylko %s MB wolnego na /.'
MSG[chk_disk_ok]='%s MB wolnego na /.'
MSG[chk_optimized]='Optymalizacja zastosowana.'
MSG[chk_not_optimized]='Optymalizacja niezastosowana (tryb optimize).'
MSG[chk_summary]='Wynik: błędy: %s, ostrzeżenia: %s.'
MSG[step_status]='STATUS'
MSG[status_line]='Wersja %s, profil %s, konfiguracja %s'
MSG[status_sealed]='Obraz jest ZAMKNIĘTY (sealed).'
MSG[status_unsealed]='Obraz nie jest zamknięty.'

# --- collab / apps / seal additions ---
MSG[menu_apps]='5. Dodatkowe aplikacje (apps/*.sh, np. Eclipse)'
MSG[menu_collab]='7. Session Collaboration (pyta o każde ustawienie, link UAG)'
MSG[seal_guard_msg]='Obraz VDI jest zamknięty - zmiany pakietów zablokowane. Uruchom: vdi-imagemaint.sh unlock (lub update)'
MSG[seal_packages_blocked]='Zmiany pakietów zablokowane (apt update, apt install, dpkg -i) do czasu unlock.'
MSG[seal_users_quiet]='Użytkownicy pulpitu nie zobaczą okien pakietów, colord ani błędów systemu.'
MSG[tmpfs_next_boot]='/tmp w pamięci RAM od następnego uruchomienia.'
MSG[step_collab]='COLLAB - Horizon Session Collaboration'
MSG[collab_q_enable]='Włączyć Session Collaboration? (tak/nie)'
MSG[collab_q_url]='Link w zaproszeniach - adres zewnętrzny, np. UAG (https://..., puste = domyślny agenta)'
MSG[collab_q_email]='Zezwolić na zaproszenia e-mailem? (tak/nie)'
MSG[collab_q_control]='Zezwolić współpracownikom na przejęcie klawiatury/myszy? (tak/nie)'
MSG[collab_q_max]='Maksymalna liczba współpracowników w sesji'
MSG[collab_invalid]='Niepoprawna wartość - spróbuj ponownie (obecnie domyślnie: %s).'
MSG[collab_summary]='Collaboration: włączone=%s, link=%s, e-mail=%s, przekazywanie sterowania=%s, maks.=%s'
MSG[collab_q_apply]='Zapisać te ustawienia w konfiguracji agenta w %s?'
MSG[collab_cancelled]='Nic nie zmieniono.'
MSG[collab_done]='Zapisano: %s, %s'
MSG[collab_restart]='Uruchom ponownie agenta (lub VM), aby zmiana zadziałała; klony dostaną ją z następnym Push Image.'
MSG[step_apps]='APPS - dodatkowe aplikacje'
MSG[apps_running]='Uruchamiam %s --install'
MSG[apps_done]='%s zakończony.'
MSG[apps_failed]='%s nie powiódł się - zobacz komunikaty powyżej.'
MSG[apps_none]='Brak skryptów aplikacji w %s.'

# --- domain / certificate logon / FIDO ---
MSG[step_domain]='DOMAIN - Active Directory (SSSD) dla offline join Instant Clone'
MSG[dns_srv_ok]='Kontrolery domeny %s znalezione w DNS.'
MSG[domain_already_joined]='Już dołączono do %s.'
MSG[domain_joining]='Dołączanie do %s jako %s (komputer: %s) - podaj hasło, gdy pojawi się pytanie.'
MSG[domain_join_failed]='Dołączenie do %s nie powiodło się - zobacz komunikaty powyżej.'
MSG[sudoers_invalid]='Wpis sudoers dla "%s" jest niepoprawny - nie zapisano.'
MSG[domain_done]='Domena %s skonfigurowana.'
MSG[agent_not_joined]='Obraz wzorcowy nie jest w domenie %s - najpierw wykonaj krok domain.'
MSG[chk_joined_ok]='Obraz wzorcowy w domenie %s, keytab obecny.'
MSG[chk_joined_bad]='Brak dołączenia do %s lub brak /etc/krb5.keytab (tryb domain).'
MSG[cert_ca_missing]='Nie znaleziono certyfikatu CA %s (CERT_CA_FILES).'
MSG[cert_ca_invalid]='%s nie jest certyfikatem PEM.'
MSG[cert_ca_none]='True SSO / karta włączone, ale CERT_CA_FILES jest puste.'
MSG[chk_cert_ok]='Logowanie certyfikatem gotowe (baza CA SSSD, pam_cert_auth, pcscd).'
MSG[chk_cert_bad]='Logowanie certyfikatem niekompletne: brak bazy CA SSSD, pam_cert_auth lub pcscd.socket (tryb domain).'
MSG[chk_fido_ok]='fido2-token obecny do testu przekierowania FIDO2.'
MSG[chk_fido_bad]='Brak fido2-token - przed seal wykonaj tryb agent z FIDO_ENABLE=yes.'
MSG[step_fido]='FIDO - test przekierowania FIDO2 (uruchom w sesji Horizon na klonie)'
MSG[fido_tools_missing_sealed]='Brak fido2-token, a obraz jest zamknięty - ustaw FIDO_ENABLE=yes i przebuduj.'
MSG[fido_found]='Urządzenia FIDO2 widoczne w tej sesji: %s - przekierowanie działa na poziomie urządzenia.'
MSG[fido_none]='Brak widocznego urządzenia FIDO2 - podłącz klucz przez przekierowanie USB w kliencie Horizon (USB_ENABLE/FIDO_ENABLE, sterownik VHCI).'
MSG[menu_domain]='2. Active Directory: Kerberos, SSSD, dołączenie (+ True SSO / karta)'
MSG[menu_fido]='Test przekierowania FIDO2 (w sesji na klonie)'

# --- 0.2.0: versions, agent dependencies, USB VHCI, Recording ---
MSG[step_already_done]='Krok %s wykonany już wersją %s (%s) z tą samą konfiguracją - pominięto (--force wykona ponownie).'
MSG[step_rerun]='Krok %s wykonała wersja %s - wykonuję ponownie dla %s lub zmienionej konfiguracji.'
MSG[agent_version_unknown]='Agent Horizon jest zainstalowany, ale to narzędzie nie zapisało jego wersji - uruchamiam instalator jako aktualizację.'
MSG[agent_downgrade]='Zainstalowany agent %s jest nowszy niż archiwum %s - odmowa (--force, aby obniżyć wersję).'
MSG[agent_up_to_date]='Agent Horizon %s już zainstalowany z tymi samymi opcjami (%s) - instalator nie został uruchomiony.'
MSG[agent_action]='Agent %s: zainstalowany %s, archiwum %s, opcje: %s'
MSG[agent_blast_running]='Działa BlastServer (aktywna sesja) - wyloguj wszystkie sesje lub zrestartuj VM, potem uruchom aktualizację (wymóg Omnissa).'
MSG[vhci_downloading]='Pobieram źródła sterownika USB VHCI: %s'
MSG[vhci_source_missing]='Brak źródeł USB VHCI %s, a pobranie z %s nie powiodło się - skopiuj plik do Horizon/.'
MSG[vhci_present]='Sterownik USB VHCI %s już zainstalowany dla jądra %s.'
MSG[vhci_patch_missing]='Nie znaleziono łatki VHCI %s w archiwum agenta.'
MSG[vhci_secure_boot]='Włączony UEFI Secure Boot: moduły VHCI trzeba podpisać i zarejestrować klucz MOK (kroki VHCI w dokumentacji Omnissa).'
MSG[vhci_building]='Buduję sterownik USB VHCI %s dla jądra %s (DKMS).'
MSG[vhci_patch_failed]='Łatka VHCI agenta %s nie pasuje do żadnych źródeł VHCI (także do czystych pobranych) - zobacz log.'
MSG[vhci_build_failed]='Po budowie DKMS brak modułów USB VHCI dla jądra %s.'
MSG[vhci_done]='Sterownik USB VHCI %s zainstalowany dla jądra %s (dla nowych jąder przebudowuje się sam).'
MSG[step_recording]='RECORDING - Horizon Recording Agent'
MSG[rec_disabled]='REC_ENABLE nie jest "yes" - pominięto.'
MSG[rec_url_invalid]='REC_SERVER_URL "%s" musi mieć postać https://<serwer>:9443.'
MSG[rec_needs_agent]='Najpierw zainstaluj agenta Horizon (tryb agent) - wymaga go Recording Agent.'
MSG[rec_archive_missing]='Brak Horizon.Recording.Linux.Agent-*.tar.gz w %s.'
MSG[rec_up_to_date]='Horizon Recording Agent %s już zainstalowany - pominięto (--force instaluje ponownie).'
MSG[rec_downgrade]='Zainstalowany Recording Agent %s jest nowszy niż archiwum %s - odmowa (--force).'
MSG[rec_installing]='Recording Agent: zainstalowany %s, archiwum %s, serwer %s (tryb szablonu -t).'
MSG[rec_password_prompt]='Hasło konta %s na serwerze Horizon Recording:'
MSG[rec_password_missing]='Nie podano hasła - nic nie zainstalowano.'
MSG[rec_installer_missing]='Nie znaleziono install.sh w %s.'
MSG[rec_install_failed]='Instalacja Horizon Recording Agent nie powiodła się - zobacz komunikaty powyżej.'
MSG[rec_done]='Horizon Recording Agent %s zainstalowany.'
MSG[domain_discover_failed]='realm discover %s nie powiódł się - sprawdź DNS przed dołączeniem.'
MSG[chk_deps_ok]='Pakiety zależności agenta zainstalowane.'
MSG[chk_deps_missing]='Brak pakietów zależności agenta:%s (tryb agent).'
MSG[chk_vhci_ok]='Sterownik USB VHCI dostępny dla jądra %s.'
MSG[chk_vhci_bad]='Brak sterownika USB VHCI dla jądra %s - przekierowanie USB (USB 3.0, FIDO2) nie zadziała. Uruchom tryb usb.'
MSG[chk_rec_ok]='Usługa Horizon Recording Agent włączona.'
MSG[chk_rec_bad]='Brak usługi Horizon Recording Agent lub jest wyłączona (tryb recording).'
MSG[chk_cs_ok]='Connection Server %s rozwiązuje się w DNS.'
MSG[chk_cs_bad]='Connection Server %s nie rozwiązuje się - agent nie połączy się z brokerem.'
MSG[menu_recording]='Horizon Recording Agent (pyta o hasło do serwera)'
MSG[update_agent_newer]='Nowszy agent Horizon w Horizon/: %s -> %s - aktualizuję.'
MSG[update_rec_newer]='Nowszy Horizon Recording Agent w Horizon/: %s -> %s - aktualizuję.'

# --- 0.3.0: adopt ---
MSG[step_adopt]='ADOPT - przejęcie istniejącego obrazu wzorcowego'
MSG[adopt_sealed]='Obraz jest zamknięty - najpierw wykonaj unlock.'
MSG[adopt_os_untested]='To nie Debian 12 - wykrywanie i podgląd działają; bez Twojej odpowiedzi nic się nie zmieni.'
MSG[adopt_desktop]='Sesje pulpitu: %s; menedżer logowania: %s; domyślny cel: %s'
MSG[adopt_domain]='Dołączenie do domeny: %s; realm: %s; keytab maszyny: %s'
MSG[adopt_homes]='Katalogi domowe: %s; ustawienie SSSD: %s'
MSG[adopt_agent]='Agent Horizon zainstalowany: %s; konfiguracja: %s; OfflineJoinDomain: %s; RunOnceScript: %s; składniki USB: %s'
MSG[adopt_preview_title]='PODGLĄD - co zmieniłyby kroki budowy (nic nie jest zapisywane)'
MSG[adopt_preview_step]='--- krok %s'
MSG[adopt_preview_dm]='prepare przestawiłby menedżer logowania z %s na lightdm.'
MSG[adopt_preview_mate]='prepare zainstalowałby pulpit MATE (nie znaleziono sesji MATE).'
MSG[adopt_preview_locale]='prepare zmieniłby locale systemu z %s na %s.'
MSG[adopt_preview_tz]='prepare zmieniłby strefę czasową z %s na %s.'
MSG[preview_same]='bez zmian: %s'
MSG[preview_change]='zmieniłby: %s'
MSG[preview_kv_same]='bez zmian: %s %s=%s'
MSG[preview_kv_change]='zmieniłby: %s %s: %s -> %s'
MSG[adopt_decide_title]='DECYZJA - przejęte kroki zostają bez zmian i narzędzie ich nie wykonuje (tylko z --force)'
MSG[adopt_q_step]='Zachować obecną konfigurację kroku %s (wykryto: %s)?'
MSG[adopt_step_marked]='Krok %s przejęty - narzędzie go nie nadpisze.'
MSG[adopt_agent_known]='Wersja agenta %s jest już zapisana.'
MSG[adopt_q_agent_version]='Zainstalowana wersja agenta Horizon (YYMM-y.y.y-build) [%s]:'
MSG[adopt_agent_version_unknown]='Wersja agenta nie została zapisana - tryb agent uruchomi instalator jako aktualizację.'
MSG[adopt_q_agent_args]='Czy agent był instalowany z opcjami obecnej konfiguracji (%s)?'
MSG[adopt_agent_recorded]='Agent zapisany jako %s (opcje: %s) - bez reinstalacji.'
MSG[adopt_runonce_chained]='Zachowano istniejący RunOnceScript %s: wywołuje go skrypt klona narzędzia.'
MSG[adopt_done]='Obraz przejęty. Zachowane kroki: %s. Dalej: check, potem w razie potrzeby optimize / collab / seal.'
MSG[agent_offlinejoin_kept]='OfflineJoinDomain bez zmian (przejęty obraz dołączony przez %s).'
MSG[step_adopted]='Krok %s przejęty z istniejącego obrazu (%s) - pominięto (--force zastosuje ustawienia narzędzia).'
MSG[chk_offlinejoin_adopted]='OfflineJoinDomain ustawione (przejęty obraz, metoda dołączenia %s).'
MSG[chk_join_service_ok]='%s działa.'
MSG[chk_join_service_bad]='%s nie działa.'
MSG[chk_desktop_adopted]='Przejęty pulpit z menedżerem logowania %s (nie testowane LightDM + MATE).'
MSG[chk_nfs_adopted]='Katalogi domowe przejęte z istniejącego obrazu (%s).'
MSG[menu_adopt]='0. Istniejący obraz: wykryj, pokaż różnice, zachowaj (adopt)'

# --- 0.3.1: adopt creates the configuration ---
MSG[adopt_q_profile]='Profil tego obrazu - university lub business [%s]:'
MSG[adopt_config_title]='KONFIGURACJA - ustawienia wykryte na tym obrazie'
MSG[adopt_config_header]='Utworzone przez VDI-ImageMaint %s adopt dnia %s (%s) z ustawień znalezionych na tym obrazie.'
MSG[adopt_config_header2]='Pozostałe ustawienia biorą się z conf/defaults.conf i profilu; tu możesz je dopisać lub zmienić.'
MSG[adopt_config_created]='Konfiguracja utworzona z wykrytych ustawień: %s'
MSG[adopt_config_exists]='%s już istnieje i nie została zmieniona - wykryte wartości zapisano w %s'
MSG[adopt_config_diff]='różnica: %s: w konfiguracji %s, wykryto %s'

# --- 0.3.2 ---
MSG[chk_deps_missing_installed]='Brak zależności instalatora agenta:%s - zainstalowany agent działa bez nich; doinstaluj je przed następną aktualizacją agenta.'
MSG[chk_cs_example]='HORIZON_CS_FQDN ma nadal wartość przykładową %s - wpisz w vdi-imagemaint.conf prawdziwą nazwę Connection Server (albo zostaw puste).'
MSG[step_usb]='USB - sterownik VHCI do przekierowania USB (bez reinstalacji agenta)'
MSG[usb_no_patch]='Brak łatki VHCI w zainstalowanym agencie i brak instalatora agenta w: %s - umieść tam Omnissa-horizonagent-linux-x86_64-*.tar.gz (albo rozpakowany katalog).'
MSG[usb_patch_from]='Łatka VHCI pobrana z %s.'
MSG[usb_agent_component_missing]='Agent nie ma składnika USB (instalowany bez -U yes): uruchom tryb agent z USB_ENABLE="yes" (ta sama wersja: --force), aby przekierowanie USB działało.'
MSG[menu_usb]='Sam sterownik przekierowania USB (VHCI) - także dla przejętego obrazu'
MSG[adopt_runonce_set]='Skrypt klona %s ustawiony jako RunOnceScript w %s (nowe klucze SSH i odświeżenie SSSD/NFS na każdym klonie).'
MSG[chk_conf_example]='W konfiguracji zostały wartości przykładowe:%s - ustaw je w %s.'
MSG[chk_conf_example_detected]='W konfiguracji zostały wartości przykładowe:%s - wartości wykryte na tym obrazie są w %s (przepisz je).'

# --- 0.4.0: self-update ---
MSG[selfupdate_unreachable]='GitHub niedostępny - kontynuuję z zainstalowaną wersją.'
MSG[selfupdate_current]='VDI-ImageMaint %s to najnowsze wydanie.'
MSG[selfupdate_available]='Nowsze wydanie VDI-ImageMaint: %s -> %s.'
MSG[selfupdate_q]='Zaktualizować narzędzie do %s teraz?'
MSG[selfupdate_failed]='Aktualizacja do %s nie powiodła się - kontynuuję z zainstalowaną wersją.'
MSG[selfupdate_done]='Narzędzie zaktualizowane do %s - uruchamiam polecenie ponownie w nowej wersji.'
MSG[selfupdate_runonce]='Skrypt klona %s zaktualizowany do tej wersji narzędzia.'
MSG[step_selfupdate]='SELF-UPDATE - sprawdzenie nowszego wydania na GitHubie'
MSG[menu_self-update]='Zaktualizuj to narzędzie z GitHuba teraz'
MSG[vhci_source]='Źródła VHCI: %s'
MSG[vhci_already_patched]='Źródła VHCI mają już łatkę Omnissa - nie nakładam jej ponownie.'
MSG[vhci_patch_no_fit]='Łatka VHCI agenta nie pasuje do %s (zmienione źródła albo łatka innej wersji agenta) - próbuję kolejnego źródła; szczegóły w logu.'

# --- 0.5.0: Kerberos/SSSD robustness ---
MSG[step_kerberos]='KERBEROS - hasło komputera, synchronizacja czasu i odnawianie biletów dla SSSD'
MSG[krb_not_sssd]='Obraz nie jest dołączony przez SSSD - ustawienia Kerberos pominięte.'
MSG[krb_harden]='Ustawienia bezpieczeństwa Kerberos/SSSD dla %s (bez automatycznej zmiany hasła komputera, SSSD czeka na synchronizację czasu, odnawianie biletów).'
MSG[krb_hardened]='Ustawienia bezpieczeństwa Kerberos/SSSD aktywne.'
MSG[krb_rotated]='Hasło konta komputera zmienione (jeśli starsze niż %s dni) - nowy snapshot ma aktualny keytab.'
MSG[krb_rotate_failed]='Hasło konta komputera nie zostało zmienione (keytab odrzucony lub błąd adcli update) - sprawdź: adcli testjoin.'
MSG[chk_testjoin_ok]='Konto komputera w %s akceptuje ten keytab (adcli testjoin).'
MSG[chk_testjoin_bad]='Konto komputera w %s NIE akceptuje tego keytabu - logowanie nie zadziała. Przywróć snapshot z keytabem akceptowanym przez AD albo dołącz ponownie (najpierw kopia /etc/sssd/sssd.conf), potem nowy snapshot.'
MSG[chk_krb_hardened]='Ustawienia bezpieczeństwa Kerberos/SSSD obecne.'
MSG[chk_krb_not_hardened]='Brak ustawień bezpieczeństwa Kerberos/SSSD - uruchom tryb kerberos.'
MSG[menu_kerberos]='Kerberos/SSSD: hasło komputera, czas, odnawianie biletów (logowanie po wyłączeniu VM)'
MSG[krb_no_domain]='Nie znaleziono prawdziwej domeny SSSD ("domains" w sssd.conf; AD_DOMAIN puste lub przykładowe) - ustawienia Kerberos nie zostały zapisane.'
MSG[krb_no_timesyncd]='Zegar nie jest synchronizowany przez systemd-timesyncd (chrony lub VMware Tools?) - SSSD nie czeka na synchronizację czasu.'
MSG[krb_rolled_back]='Ustawienia Kerberos/SSSD WYCOFANE - %s nie przeszło z nimi; SSSD działa na poprzedniej konfiguracji.'
MSG[adopt_q_kerberos]='Zastosować ustawienia bezpieczeństwa Kerberos/SSSD (bez automatycznej zmiany hasła komputera, czas, odnawianie biletów; wycofywane automatycznie, jeśli SSSD ich nie przyjmie)?'
