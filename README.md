# BookScan AG — versione 0.2 (qualità bilanciata)

App SwiftUI per iPhone, senza backend e senza OCR interno: acquisisce una foto del libro aperto, la separa in **due pagine** e crea un PDF da inviare a ChatGPT per la trascrizione.

## Funzionalità disponibili
- Fotocamera posteriore, **scatto manuale**.
- Linea regolabile (30–70%) per separare pagina sinistra e destra.
- Elaborazione locale: scala di grigi, contrasto leggero (1,12), lato lungo massimo **1800 px** per pagina, **JPEG qualità 0,80**.
- Conservazione in memoria dei JPEG compressi invece delle foto originali.
- Anteprime, eliminazione dell'ultima coppia, esportazione PDF e condivisione iOS.
- Dimensione effettiva del PDF mostrata dopo l'esportazione.

**Nota importante:** 5–12 MB per 50 pagine è un *obiettivo da verificare*, non un limite garantito. La dimensione dipende dalle foto, dalla carta e dall'encoder PDF di iOS. Anche la leggibilità OCR va verificata con pagine reali. Il PDF contiene immagini, non testo ricercabile.

## Non ancora disponibili
- Scatto automatico al cambio pagina, riconoscimento automatico della rilegatura, ritaglio del tavolo, correzione prospettica, correzione curvatura, salvataggio persistente di una libreria.
- La linea gialla è una guida: la fotocamera usa anteprima *aspect fill*, quindi la posizione sullo schermo potrebbe non corrispondere esattamente al taglio della foto. Controllare le anteprime e regolare se necessario.
- Le pagine acquisite restano in memoria fino alla chiusura dell'app. Per libri lunghi, esportare a blocchi; una versione successiva potrà salvarle su disco progressivamente.

## GitHub Actions
1. Crea un repository GitHub e carica **il contenuto della cartella BookScanAG nella radice** (non la cartella contenitore).
2. Conserva la cartella nascosta `.github/workflows/`.
3. Apri **Actions → Build iOS IPA → Run workflow** oppure esegui un push su `main`.
4. Scarica l'artifact **BookScanAG-unsigned** che contiene l'IPA non firmata.

La build non è stata verificata su macOS in questo ambiente. L'IPA non firmata **non è direttamente installabile**: servirà un flusso di firma compatibile con SideStore/LiveContainer. Su GitHub Actions i runner macOS dei repository privati consumano quote maggiorate; i runner standard per repository pubblici sono gratuiti.

## Privacy
L'app non trasmette scansioni in rete. La condivisione del PDF con ChatGPT è una scelta esplicita dell'utente tramite il foglio di condivisione iOS.
