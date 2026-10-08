# Moonraker Printer Plus dla Omarchy (PL)

Widget do bara [Omarchy](https://omarchy.org), który pokazuje stan drukarki 3D
z Klipperem i [Moonrakerem](https://github.com/Arksine/moonraker). Działa
z każdą taką drukarką: Qidi (testowane na Q2), Elegoo Centauri Carbon z COSMOS
i Canvas, Voron, RatRig, Creality K-series z Klipperem i innymi.

> **Podziękowania.** To rozszerzony fork pluginu
> [**Moonraker Printer**](https://github.com/prodpixa/omarchy-moonraker) autorstwa
> [prodpixa](https://github.com/prodpixa), który stworzył ten widget. Jego praca
> jest używana na licencji MIT, a jego informacja o prawach autorskich zostaje
> w [LICENSE](../LICENSE). Ta wersja dodaje kamerę, tory zmieniacza filamentu
> AFC, powiadomienia, narzędzia wydruku i Spoolman.

<p align="center"><img src="screenshots/08-printing.png" width="400"></p>

## Co potrafi

- **W barze** do wyboru trzy style:
  - sama ikonka,
  - procent i czas do końca,
  - procent, czas i wybrane temperatury (dysza, stół, komora).
- **Popup** po kliknięciu:
  - miniatura modelu,
  - czas wydruku, czas do końca i godzina zakończenia,
  - warstwa i zużyty filament,
  - temperatury: aktualna i docelowa,
  - podgląd z kamery drukarki (ustawionej w Mainsail/Fluidd), odświeżany mniej więcej co sekundę i tylko przy otwartym popupie; żarówka w rogu obrazu włącza i wyłącza oświetlenie komory (klawisz `l`).
- **Zmieniacz filamentu** (AFC: Elegoo Canvas, Box Turtle, Night Owl, …): wszystkie
  tory z kolorem, narzędziem, materiałem i pozostałą wagą, informacja, który
  filament jest w głowicy, oraz podgląd zmiany na żywo: stary → nowy filament,
  wyładowanie / ładowanie / wznowienie i „zmiana 3 z 12” przy wydrukach
  wielokolorowych. W trakcie zmiany chip w barze pokazuje docelowe narzędzie.
- **Powiadomienia** na pulpicie: koniec wydruku, pauza (np. koniec filamentu),
  błąd, „zostało 10 minut” oraz błędy Klippera i zmieniacza filamentu, ze
  zdjęciem z kamery, żeby od razu widzieć gotowy model albo problem.
- **Spoolman** (w Tools, gdy Moonraker ma skonfigurowany Spoolman): aktywna
  szpula z kolorem i pozostałymi gramami oraz lista do zmiany szpuli. Przy AFC
  osobny wiersz dla każdego toru, żeby przypisać lub usunąć jego szpulę.
- **Sterowanie**: pauza, wznowienie i anulowanie. Anulowanie trzeba kliknąć drugi raz, żeby potwierdzić.
- **Narzędzia wydruku** (przycisk Tools albo klawisz `t`): pauza na
  wybranej warstwie albo po bieżącej (między wydrukami: dla następnego wydruku), np. żeby włożyć magnesy (wymaga standardowych
  makr pauzy z Mainsail/Fluidd i slicera, który podaje numery warstw), oraz
  pominięcie jednego obiektu z płyty, gdy się nie udał, bez przerywania reszty
  (wymaga `[exclude_object]`).
- **Obsługa wszystkich stanów**:
  - brak konfiguracji, brak połączenia, brak lub zły API key,
  - Klipper uruchamia się, jest rozłączony albo w stanie shutdown,
  - bezczynność, nagrzewanie, druk, pauza, koniec, anulowanie, błąd.
  
  Zrzuty ekranu wszystkich stanów są w [STATES.md](STATES.md).
- **API key**: dzięki niemu działa przez VPN i z innych sieci.
- **Wygląd jak natywny**: kolory, czcionka i kontrolki pochodzą z Omarchy,
  więc widget zmienia się razem z `omarchy theme set`.
- **Lekko i bezpiecznie**: każde zapytanie to krótkie wywołanie `curl` (jest w każdej instalacji Arch) z limitem 1 MB i 10 s, więc źle działająca drukarka nie zawiesi ani nie zapcha shella.

## Instalacja

```bash
omarchy plugin add https://github.com/saurasanchezpablo/omarchy-moonraker.git --enable
```

Wymagania: Omarchy z shellem Quattro, drukarka z Klipperem i Moonrakerem,
`curl` i `notify-send` (oba są w Omarchy). Kamera, AFC, makra pauzy,
`[exclude_object]` i Spoolman są opcjonalne. Bez uprawnień roota i bez zmian w systemie.

Jeśli masz oryginalny Moonraker Printer, najpierw go usuń
(`omarchy plugin remove io.github.prodpixa.moonraker`) i wpisz adres ponownie:
oba pluginy mają osobne ustawienia.

Potem kliknij ikonkę drukarki. Popup otworzy się na ustawieniach: wpisz adres
(np. `http://192.168.1.50`), opcjonalnie API key, i kliknij **Save & connect**.

## Odinstalowanie

```bash
omarchy plugin remove io.github.saurasanchezpablo.moonraker-plus
```

Usuwa widget z baru, jego ustawienia (razem z API key) z `shell.json` i folder
pluginu. `omarchy plugin disable io.github.saurasanchezpablo.moonraker-plus` też usuwa widget i ustawienia, ale zostawia folder.

## Obsługa

| Akcja | Efekt |
|-------|-------|
| Lewy klik | popup ze szczegółami |
| Prawy klik | zmiana stylu w barze: ikonka → postęp → postęp + temperatury |
| Środkowy klik | otwiera panel WWW drukarki (Fluidd/Mainsail) |
| `r` / `s` / `o` w popupie | odśwież / ustawienia / otwórz WWW |

## Ustawienia

Zapisują się we wpisie widgetu w `~/.config/omarchy/shell.json`:

| Klucz | Opis |
|-------|------|
| `url` | adres Moonrakera, np. `http://192.168.1.50` albo `http://drukarka.local:7125` |
| `apiKey` | klucz API wysyłany jako nagłówek `X-Api-Key` |
| `display` | styl w barze: `icon`, `progress` albo `full` |
| `temps` | temperatury w stylu `full`: `nozzle`, `bed`, `chamber` |
| `pollInterval` | co ile sekund odświeżać (domyślnie 5; w trakcie druku i przy otwartym popupie co najwyżej 3 s) |
| `compactWhenIdle` | gdy nic się nie drukuje, pokazuj tylko przygaszoną ikonkę (dalej klikalną); to przełącznik w popupie |
| `hideWhenIdle` | całkowicie ukryj widget, dopóki nic się nie drukuje. Ustawienia są w popupie widgetu, więc ta opcja jest dostępna tylko w `shell.json` albo przez IPC. Żeby go przywrócić: `omarchy-shell io.github.saurasanchezpablo.moonraker-plus configure '{"hideWhenIdle":false}'` |
| `hideWhenOffline` | ukryj widget, gdy drukarka jest niedostępna |
| `chamberObject` | obiekt Klippera z temperaturą komory; pusty oznacza automatyczne wykrywanie |
| `showCamera` | pokazuj kamerę drukarki w popupie (domyślnie tak); przełącznik jest w ustawieniach, gdy drukarka ma kamerę |
| `notify` | powiadomienia na pulpicie (przez `notify-send`), domyślnie włączone |
| `notifySnapshot` | dołączaj do powiadomień zdjęcie z kamery (domyślnie tak) |
| `lightObject` | obiekt Klippera z oświetleniem komory, np. `led case`; pusty oznacza automatyczne wykrywanie |
| `showFilament` | pokazuj tory zmieniacza filamentu i zmiany narzędzia (domyślnie tak); działa tylko z [AFC](https://github.com/ArmoredTurtle/AFC-Klipper-Add-On) |
| `webcam` | nazwa kamery z Mainsail/Fluidd; pusta oznacza pierwszą. Przy kilku kamerach kliknięcie obrazu przełącza na następną |

Klucz API jest zapisany w `shell.json` otwartym tekstem, tak jak inne ustawienia widgetów Omarchy.

## Sterowanie ze skryptów

```bash
omarchy-shell io.github.saurasanchezpablo.moonraker-plus status          # stan w JSON (bez API key)
omarchy-shell io.github.saurasanchezpablo.moonraker-plus refresh
omarchy-shell io.github.saurasanchezpablo.moonraker-plus cycleDisplay
omarchy-shell io.github.saurasanchezpablo.moonraker-plus showSettings
omarchy-shell io.github.saurasanchezpablo.moonraker-plus configure '{"display":"full"}'
```

`configure` przyjmuje wszystkie ustawienia oprócz `apiKey`: JSON jest argumentem
polecenia, więc klucz byłby widoczny na liście procesów i w historii powłoki.
Klucz wpisz w ustawieniach w popupie.

## Dla deweloperów

- `dev/install.sh`: instaluje kopię roboczą i restartuje shell.
- `dev/mock_moonraker.py`: atrapa drukarki ze scenariuszami (`/mock/scenario/<nazwa>`).
- `dev/screenshots.sh`: przechodzi przez wszystkie stany i robi zrzuty do `docs/screenshots/`.

Więcej informacji:

- [ARCHITECTURE.md](ARCHITECTURE.md): jak to działa w środku,
- [CONTRIBUTING.md](../CONTRIBUTING.md): zgłaszanie błędów, środowisko deweloperskie i testowanie, w tym lista kontrolna na prawdziwej drukarce.
