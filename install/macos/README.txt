Agent Cockpit — macOS-Installation
==================================

Dieses Paket enthält:

  /Applications/Agent Cockpit.app         der Kopplungs-Helfer
  /usr/local/bin/agent-cockpit-install    das öffentliche Installationsprogramm

Es enthält KEINE Zugangsdaten, keinen Schlüssel und keine Adresse eines
Cockpits. Der Kopplungslink im Cockpit trägt die Angaben, die zu deinem
Cockpit gehören.

Nächste Schritte
----------------

1. Öffne das Agent Cockpit im Browser (auf demselben Mac).
2. Wähle „Computer verbinden" → „Auf meinem Mac".
3. Klicke „Diesen Mac koppeln".

Der Browser öffnet dann „Agent Cockpit" mit dem Kopplungslink. Das Programm
fragt nichts ab und braucht kein Terminal: es installiert den Connector für
dich, richtet den Hintergrunddienst ein und koppelt diesen Mac.

Hinweis zur Signierung
----------------------

Dieses Paket ist NICHT signiert und NICHT notarisiert, weil hierfür kein
Apple-Developer-Zertifikat vorliegt. macOS (Gatekeeper) zeigt deshalb beim
ersten Öffnen einen Warnhinweis und verlangt eine Bestätigung. Das ist zu
erwarten und keine Fehlfunktion. Signieren und Notarisieren würden nur weitere
Schritte um dasselbe Paket herum ergänzen.

Deinstallieren
--------------

  sh /usr/local/bin/agent-cockpit-install --uninstall

Der Ordner „Agent Cockpit.app" kann zusätzlich in den Papierkorb gelegt werden.
Die Agentendaten bleiben bei --uninstall erhalten; --purge entfernt sie.
