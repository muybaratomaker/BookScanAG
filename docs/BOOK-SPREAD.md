# Ritaglio e modalità Libro aperto

## Diagnosi del ritaglio

La pipeline precedente creava realmente `cropped.png`, ma per ogni rilevamento
`needsReview` sceglieva `selectedVariant = .original`. Anteprima e PDF usavano quindi
la foto intera: il ritaglio esisteva, ma era scartato nella scelta di esportazione.
Inoltre il contorno live era un rilevamento stabilizzato diverso da quello della
foto, mentre il contorno salvato rappresentava la maschera senza il margine effettivo.
Non abbiamo misurato quale di questi fattori domina nelle fotografie dell'utente:
non erano presenti immagini reali nel workspace.

Ora il rilevamento produce una candidata ritagliata visibile; un risultato incerto
rimane «Da controllare» e il PDF richiede conferma esplicita. Senza rilevamento resta
l'originale, segnalato, senza un ritaglio automatico inventato. I contorni di revisione
sono ricavati dai pixel del ritaglio applicato, inclusi margine, arrotondamento e limiti.
Il margine predefinito è 3% (prima 7%). Si conserva l'originale integrale.

`CropCoordinates` converte coordinate normalizzate della **foto raddrizzata via EXIF**
in pixel CGImage. Le coordinate della preview non vengono trasferite direttamente
alla foto: il rilevamento viene ripetuto sulla fotografia. La preview usa aspect-fit,
con rapporto del video effettivo, non aspect-fill. Nessuna specchiatura è aggiunta.

## Libro aperto

Il selettore in fotocamera offre Pagina singola / Libro aperto (2 pagine). La stima
classica della rilegatura usa l'inviluppo della carta e un solco scuro con carta
chiara sui lati in almeno 7 di 9 fasce, con controllo di inclinazione e coerenza.
La rilegatura può essere decentrata o inclinata: non è un taglio fisso al 50% e non
è una nuova rete neurale di segmentazione. Un bordo esterno raro ma più sporgente
viene incluso nel ritaglio per evitare di eliminare testo.

Le pagine sono ritagliate separatamente in ordine sinistra-destra. UVDoc, se attivato,
è eseguito su ciascun ritaglio affidabile, mai sull'intero libro del fallback.
I margini esterni si espandono; al centro è mantenuta solo la sovrapposizione
necessaria a non tagliare la rilegatura inclinata. Non viene inventato testo nascosto.

Se manca evidenza per due pagine, viene salvata **una sola foto da controllare**.
In Controlla pagina, «Dividi in due pagine…» consente di regolare l'area del libro
e le estremità superiore/inferiore della rilegatura. «Applica alle due pagine» è
un'azione esplicita e rigenera i ritagli dall'originale. Ogni pagina ha anche
ritaglio manuale indipendente, scelta Originale/Ritagliata/Corretta e cancellazione.
Selezionare Ritagliata disattiva UVDoc su quella pagina.

## Conservazione e ordine

Le due pagine condividono fisicamente la foto originale immutabile tramite hard link;
eliminare una pagina non elimina l'originale dell'altra. L'indice mantiene l'ordine
inserendo la destra subito dopo la sinistra, anche se una foto successiva è già presente.
Il ripristino non riordina l'indice per data. Un ritaglio nuovo invalida la vecchia
correzione, che non può ricomparire dopo il riavvio. Le miniature hanno una revisione
persistente per invalidare la cache dopo una rielaborazione.

La coda elabora uno scatto per volta; durante l'elaborazione il nuovo scatto è
disabilitato ma la preview rimane nativa. Un libro viene decodificato al massimo a
4200 px sul lato lungo, così ogni pagina conserva più dettaglio del vecchio limite
2600 px sull'intero libro. Non è stata misurata la memoria/temperatura su iPhone.

## Test e verifica

Eseguibili su Linux con Swift (sorgenti reali, fixture sintetiche):

```sh
swiftc ScanGeometry.swift Tests/Geometry/main.swift -o /tmp/geometry && /tmp/geometry
swiftc ScanGeometry.swift ScanSpreadGeometry.swift Tests/Spread/main.swift -o /tmp/spread && /tmp/spread
swiftc CropCoordinates.swift Tests/Crop/main.swift -o /tmp/crop && /tmp/crop
swiftc ScanPDFExporter.swift Tests/PDFWriterTests.swift -o /tmp/pdf && /tmp/pdf
```

Su macOS, il test Crop esegue anche ritaglio su pixel CoreGraphics e normalizzazione
EXIF ImageIO. Il workflow esegue inoltre il vero store con hard link, cancellazione,
riavvio, ordine e invalidazione delle correzioni:

```sh
swiftc ScanProcessingTypes.swift ScanSessionStore.swift Tests/StorageTests.swift -o /tmp/storage
/tmp/storage
```

Le prove macOS/iOS non sono eseguibili nel workspace Linux. I test sintetici non
provano la qualità su libri universitari, mani, tastiere, ombre o carta simile al tavolo.
Una riga verticale scura stampata può ancora essere scambiata per rilegatura; bordi
non visibili o assenza di ombra possono richiedere la divisione manuale. La correzione
prospettica non è un nuovo stadio separato: la geometria resta quella di UVDoc quando
la mappa supera i controlli esistenti.

Per accettare la versione: eseguire la build GitHub Actions, verificare UVDoc.mlmodelc,
provare su iPhone 15 una pagina decentrata e un libro con rilegatura decentrata/inclinata;
controllare tutte le parole presso il centro, cambiare la linea dopo lo scatto,
eliminare solo la sinistra e riaprire l'app. Fotografare 20 aperture valide e verificare
40 pagine PDF in ordine; i fallback incerti richiedono revisione esplicita.
