# Automatische Chart-Updates mit Renovate

Dieses Repository nutzt Renovate für automatische Updates der Upstream-Charts und GitHub Actions für das automatische Rebuilding.

## Wie es funktioniert

### 1. Renovate überwacht Upstream-Versionen

Renovate ist konfiguriert ([renovate.json](../renovate.json)), um:
- Das offizielle Traefik Helm Repository zu überwachen
- Neue Chart-Versionen zu erkennen
- Automatisch Pull Requests zu erstellen, die `packages/traefik/package.yaml` aktualisieren

**Konfiguration:**
```json
{
  "regexManagers": [
    {
      "fileMatch": ["^packages/traefik/package\\.yaml$"],
      "matchStrings": [
        "url:\\s*https://traefik\\.github\\.io/charts/traefik/traefik-(?<currentValue>[0-9.]+)\\.tgz"
      ],
      "datasourceTemplate": "helm",
      "depNameTemplate": "traefik"
    }
  ]
}
```

### 2. GitHub Actions baut Charts automatisch

Wenn Renovate einen PR erstellt ([.github/workflows/renovate.yaml](../.github/workflows/renovate.yaml)):

1. **Patches anwenden**: `make prepare` lädt das neue Upstream-Chart und wendet die vorhandenen Patches an
2. **Validierung**: Überprüft, ob die Patches mit der neuen Version kompatibel sind
3. **Charts generieren**: `make charts` erstellt die finalen Chart-Pakete (.tgz)
4. **Commit**: Generierte Charts werden automatisch in den PR committed

### 3. Patch-Kompatibilität

Die Patches in `packages/traefik/generated-changes/patch/` sind in der Regel versionunabhängig, da sie:
- Hauptsächlich Werte in `values.yaml` ändern (z.B. Image-Repository)
- Template-Änderungen vornehmen, die strukturell stabil sind

**Beispiel-Patches:**
- Ändert `image.repository` von `docker.io/traefik` zu `rancher/mirrored-library-traefik`
- Setzt `global.systemDefaultRegistry`
- Deaktiviert `global.checkNewVersion`

## Workflow für Updates

### Automatischer Erfolg (90% der Fälle)

1. Renovate erstellt PR mit neuer `package.yaml`
2. GitHub Actions läuft automatisch
3. Patches werden erfolgreich angewendet
4. Charts werden gebaut und committed
5. **Manuell**: PR reviewen und mergen

**Hinweis:** Für Renovate-PRs zu Traefik werden die Chart-Artefakte automatisch
durch die GitHub Action `traefik-autobuild` gebaut und in den PR zurückgeschrieben.

### Update per OBS-Helper (manuell)

Für manuelle Updates steht `update-traefik-from-obs` bereit. Das Script
zieht die Zielversion aus OBS, aktualisiert `packages/traefik/package.yaml`,
führt den Build-Workflow aus und kümmert sich um Patch-Regeneration.

**Patch Handling:**
- Bestehende `.patch` Dateien können bei neuen Upstream-Versionen kollidieren.
- Das Script versucht automatisch semantisches Patching via
  `packages/traefik/k3s-patches.sh`.
- Mit `--force-regenerate` wird semantisches Patching immer verwendet
  (empfohlen bei Major-Versionen).

**Beispiele:**
```bash
./update-traefik-from-obs k3s-charts-1754298670.5869b83.tar.xz
./update-traefik-from-obs -y k3s-charts-1754298670.5869b83.tar.xz
./update-traefik-from-obs -r -y k3s-charts-1754298670.5869b83.tar.xz
```

### Patch-Konflikte (10% der Fälle)

Wenn die Patches nicht mehr kompatibel sind:

1. GitHub Actions schlägt fehl mit klarer Fehlermeldung
2. **Manuell**: Patches aktualisieren:

```bash
cd /home/dmkif/git/k3s-charts
export PACKAGE=traefik

# Neue Version vorbereiten
make prepare

# Manuelle Änderungen in packages/traefik/charts/ vornehmen
# z.B. values.yaml editieren, wenn sich Struktur geändert hat

# Neue Patches generieren
make patch

# Charts neu bauen
make charts

# Committen und pushen
git add packages/traefik/generated-changes/
git commit -m "fix(traefik): Update patches for new chart structure"
git push
```

## Weitere Packages automatisieren

Um weitere Charts zu automatisieren, ergänze [renovate.json](../renovate.json):

```json
{
  "regexManagers": [
    {
      "fileMatch": ["^packages/dein-package/package\\.yaml$"],
      "matchStrings": [
        "url:\\s*https://example\\.com/charts/(?<depName>.*?)/\\k<depName>-(?<currentValue>[0-9.]+)\\.tgz"
      ],
      "datasourceTemplate": "helm",
      "registryUrlTemplate": "https://example.com/charts"
    }
  ]
}
```

## Monitoring

- **Renovate Dashboard**: Aktiviere das Renovate Dashboard in deinem GitHub Repository
- **PR-Labels**: Renovate-PRs werden automatisch mit Labels versehen
- **Notifications**: GitHub benachrichtigt bei neuen PRs und fehlgeschlagenen Builds

## Vorteile

✅ **Zeitersparnis**: Keine manuellen Version-Checks mehr
✅ **Sicherheit**: Schnellere Updates bei Security-Fixes
✅ **Konsistenz**: Automatische Validierung der Patches
✅ **Nachvollziehbar**: Jedes Update ist ein eigener PR mit Änderungshistorie
✅ **Kontrolliert**: Du entscheidest, wann ein Update gemerged wird

## Konfigurationsoptionen

### Update-Häufigkeit anpassen

In [renovate.json](../renovate.json):

```json
{
  "packageRules": [
    {
      "matchPackageNames": ["traefik"],
      "schedule": ["every weekend"]  // oder "before 3am every day", "every 2 weeks"
    }
  ]
}
```

### Auto-Merge aktivieren (nur für Minor/Patch)

```json
{
  "packageRules": [
    {
      "matchPackageNames": ["traefik"],
      "matchUpdateTypes": ["minor", "patch"],
      "automerge": true
    }
  ]
}
```

### Mehrere Updates gruppieren

```json
{
  "packageRules": [
    {
      "matchPackageNames": ["traefik", "traefik-crd"],
      "groupName": "traefik"
    }
  ]
}
```

## Troubleshooting

### "Patches failed to apply"

Die Upstream-Chart-Struktur hat sich geändert. Siehe [Workflow für Updates](#workflow-für-updates) → Patch-Konflikte.

### Renovate erstellt keine PRs

- Überprüfe Renovate-Logs im Repository (Issues → Dependency Dashboard)
- Stelle sicher, dass Renovate im Repository aktiviert ist
- Prüfe, ob `renovate.json` valide ist: https://docs.renovatebot.com/config-validation/

### GitHub Actions schlagen fehl

- Überprüfe Workflow-Logs im Actions-Tab
- Stelle sicher, dass `GITHUB_TOKEN` Schreibrechte hat (Settings → Actions → General → Workflow permissions)
