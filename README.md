# Casa Control — iOS / AltStore

App SwiftUI per iPhone e iPad (iOS 16+), con accensione/spegnimento, stato dei dispositivi, aggiornamento manuale e token nel Portachiavi. Due connessioni alternative: Tapo tramite bridge locale incluso; Tapo e Smart Life/Tuya insieme tramite Home Assistant.

## Smart Life/Tuya e Tapo insieme (consigliato)

1. Installa Home Assistant su un computer/Raspberry Pi sempre acceso.
2. Configura l'integrazione **Tuya** e collega il tuo account Smart Life seguendo la procedura di Home Assistant: https://www.home-assistant.io/integrations/tuya/ .
3. Configura anche **TP-Link Smart Home** per Tapo: https://www.home-assistant.io/integrations/tplink/ .
4. Dal tuo profilo Home Assistant crea un token di accesso a lunga durata.
5. Nell'app, Impostazioni → Home Assistant, inserisci URL dell'istanza (es. `http://homeassistant.local:8123`) e token, quindi Salva.

L'app controlla entità light, switch, fan e input_boolean. Non fornisce login diretto al cloud Smart Life/Tuya. Home Assistant deve essere raggiungibile dal telefono. Le entità non disponibili sono disabilitate. La luminosità è visualizzata, ma non è regolabile in questa versione. Telecamere, serrature, termostati e scene non sono inclusi.

## Tapo senza Home Assistant

Il bridge Python usa python-kasa per il protocollo locale Tapo; deve girare nella stessa rete dei dispositivi. Compatibilità dipendente da modello e firmware, soprattutto per hub e dispositivi a batteria: https://python-kasa.readthedocs.io/ .

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r bridge/requirements.txt
cp bridge/.env.example bridge/.env
# Modifica bridge/.env con IP locali (prenotazioni DHCP consigliate), account Tapo e un token casuale.
# Genera il token con: python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
set -a
source bridge/.env
set +a
uvicorn bridge.server:app --host 0.0.0.0 --port 8787
```

Nell'app scegli Tapo locale, URL `http://nome-computer.local:8787` e il BRIDGE_TOKEN configurato. Il nome `.local` deve risolvere via mDNS (Bonjour/Avahi) sulla tua rete. iOS consente HTTP locale per questi nomi; per indirizzi IP e domini esterni configura HTTPS con certificato attendibile. Non inserire credenziali Tapo nell'app. Il bridge espone soltanto gli host impostati sul server e richiede il token su tutte le richieste. Non esporlo direttamente su Internet. Credenziali con spazi o caratteri shell devono essere racchiuse tra apici nel file .env.

## Compilazione GitHub Actions

Il workflow `.github/workflows/build.yml` verifica il bridge su Linux e compila l'app su macOS con Xcode. Non servono certificati Apple o segreti di firma.

1. Crea un repository GitHub privato chiamato CasaControl e carica **il contenuto** di questa cartella, inclusa `.github`.
2. Usa il ramo `main`; il push avvia la compilazione. Puoi anche usare Actions → Build IPA for AltStore → Run workflow.
3. Al termine del job iOS scarica l'artifact **CasaControl-AltStore**.
4. Estrai lo ZIP per ottenere **CasaControl.ipa**.
5. In AltStore Classic sul telefono apri My Apps → `+` e scegli l'IPA. AltStore/AltServer firmano con il tuo Apple ID. Con account gratuito la firma va normalmente rinnovata ogni 7 giorni.

L'IPA generato non è firmato e non si installa toccandolo direttamente in File. Questa procedura è per AltStore Classic con sideload personale; AltStore PAL ha requisiti di distribuzione diversi.

## Sviluppo e verifiche

Su Mac: `brew install xcodegen`, `xcodegen generate`, apri CasaControl.xcodeproj. Per simulatore seleziona un dispositivo in Xcode; per iPhone fisico configura il team di firma.

```bash
pip install -r bridge/requirements.txt pytest httpx
python -m pytest tests -q
```

I test verificano autenticazione, ID dispositivo, validazione dei comandi, chiamata di spegnimento e gestione degli errori. Non sostituiscono prove con dispositivi reali. Non è stata eseguita la compilazione Xcode in questo ambiente Linux; il workflow è pronto ma deve essere eseguito su GitHub prima di considerare l'IPA verificato.
