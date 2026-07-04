package com.noop.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.DirectionsRun
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Circle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.RemoveCircleOutline
import androidx.compose.material.icons.filled.Watch
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.noop.ble.SourceCoordinator
import com.noop.data.DeviceStatus
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind
import kotlinx.coroutines.launch

// MARK: - Devices
//
// Pair and manage the bands LLB reads from. WHOOP-FIRST: the WHOOP is the primary, fully-supported
// device; generic heart-rate straps (Polar / Wahoo / Coospo / Garmin HRM …) are an early, in-development
// addition. The screen is a thin UI over [com.noop.data.DeviceRegistry] (the Phase 1A/1B data layer):
// every mutation goes through an [AppViewModel] registry op, and the [SourceCoordinator] (wired in
// NoopApplication) reacts to the active-device change — so this view never touches the BLE client or the
// WHOOP path directly. Faithful Kotlin twin of Strand/Screens/DevicesView.swift.
//
// The registry's reads are one-shot suspend (not a Flow), so the screen keeps the list in a remembered
// state and reloads it after every mutation via [reload].

// MARK: - Liquid hero tokens (the liquid Devices restyle)
//
// The ACTIVE device card is the screen's hero: it floats over the day-of-sky as a translucent near-black
// frosted card so the strap name + the live battery tube stay crisp on it. Same tokens as the liquid Today
// hero (heroFill = rgba(13,14,20,.80), radius 26, white@0.11 hairline). Those Today constants are private to
// TodayScreen, so the identical values are declared here. Mirrors the iOS liquid heroCard.
private val LIQUID_HERO_FILL: Color = Color(red = 13f / 255f, green = 14f / 255f, blue = 20f / 255f, alpha = 0.80f)
private val LIQUID_HERO_RADIUS: Dp = 26.dp

@Composable
fun DevicesScreen(
    viewModel: AppViewModel,
    /** Routes to the non-destructive file-import lane (Data Sources). The Oura adopt wizard's "Keep the
     *  Oura app instead (import a file)" link and every honest Oura failure offer this. Defaults to a no-op
     *  so existing call sites keep compiling; AppRoot wires it to navigate to Data Sources. */
    onUseFileImport: () -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    val live by viewModel.live.collectAsStateWithLifecycle()

    // Liquid sky backdrop gate — the SAME "Tageszeiten-Hintergrund" preference the liquid Today honours (#698,
    // default ON). Off falls back to the flat dark canvas, so the setting governs every liquid screen alike.
    val context = LocalContext.current
    val showDayCycleBackground = remember { NoopPrefs.showDayCycleBackground(context) }

    // The current device list, reloaded after each registry op. Null while the first read is in flight.
    var devices by remember { mutableStateOf<List<PairedDeviceRow>?>(null) }
    fun reload() {
        scope.launch { devices = viewModel.pairedDevices() }
    }
    LaunchedEffect(Unit) { devices = viewModel.pairedDevices() }

    // Sheets / dialogs (mirror the Swift @State targets).
    var showAddWizard by remember { mutableStateOf(false) }
    var switchTarget by remember { mutableStateOf<PairedDeviceRow?>(null) }
    var renameTarget by remember { mutableStateOf<PairedDeviceRow?>(null) }
    var removeTarget by remember { mutableStateOf<PairedDeviceRow?>(null) }
    var deleteDataTarget by remember { mutableStateOf<PairedDeviceRow?>(null) }
    // After removing the ACTIVE device with other devices still paired, prompt to pick a new active one.
    var pickNewActive by remember { mutableStateOf(false) }

    val all = devices.orEmpty()
    val activeDevices = all.filter { it.status != DeviceStatus.archived.name }
    val removedDevices = all.filter { it.status == DeviceStatus.archived.name }
    val currentActiveName =
        all.firstOrNull { it.status == DeviceStatus.active.name }?.let { displayName(it) }
            ?: "Dein aktuelles Band"
    // Manual reconnect — same permission gate as Settings / Live (issue #1). Clears a user Disconnect
    // and starts a fresh scan/reconnect to the active strap.
    val requestReconnect = rememberRequestScan { viewModel.connect() }

    // PERF (#707): lazy scaffold — each device card is virtualized via `items(...)` (each was a direct
    // child of the eager `spacedBy(20.dp)` column, so the LazyColumn's matching spacing is identical) and
    // the static button/footer are single items. Only on-screen cards compose + are accessibility-walked.
    // Conditional rows use `if (cond) { item/items }` so a hidden section adds no row.
    LazyScreenScaffold(
        title = "Geräte",
        subtitle = "Bänder koppeln und verwalten, von denen LLB Daten liest.",
        // LIQUID SKY BACKDROP (the pilot pattern — LiquidScreenSky.kt): the time-of-day liquid sky settles
        // into the flat canvas behind the top of the screen so the frosted device cards float over it. The
        // static sky (LiquidSkyStatic inside the helper) carries no per-frame cost on this scrolling list.
        // Gated on the same "Tageszeiten-Hintergrund" setting as Today; off passes null for the plain canvas.
        topBackground = if (showDayCycleBackground) { { LiquidScreenSky() } } else null,
    ) {
        if (devices == null) {
            // The registry resolves a beat after launch. Show a calm pending note in that brief window.
            item {
            DataPendingNote(
                title = "Geräte werden vorbereitet",
                body = "LLB öffnet deine lokalen Daten. Gekoppelte Bänder erscheinen gleich hier.",
            )
            }
            return@LazyScreenScaffold
        }

        items(activeDevices) { device ->
            DeviceCard(
                device = device,
                isActive = device.status == DeviceStatus.active.name,
                isLiveConnected = device.status == DeviceStatus.active.name && live.connected,
                // The live battery belongs to whichever device is ACTIVE + connected (WHOOP, a generic
                // strap, or an FTMS machine all funnel into live.batteryPct). null otherwise.
                liveBatteryPct = if (device.status == DeviceStatus.active.name && live.connected)
                    live.batteryPct?.let { Math.round(it).toInt() } else null,
                // Firmware version from the connect handshake: only for the active, connected strap.
                liveFirmware = if (device.status == DeviceStatus.active.name && live.connected)
                    live.strapFirmware else null,
                onMakeActive = { switchTarget = device },
                onRename = { renameTarget = device },
                onRemove = { removeTarget = device },
            )
        }

        // Manual reconnect only when not already connected (hidden while the strap is live).
        if (!live.connected) {
            item {
                ReconnectDeviceButton(
                    scanning = live.scanning,
                    onReconnect = requestReconnect,
                )
            }
        }

        // Prominent "+ Gerät hinzufügen" button.
        item { AddDeviceButton(onClick = { showAddWizard = true }) }

        if (removedDevices.isNotEmpty()) {
            item { Overline("Entfernt", modifier = Modifier.padding(top = 4.dp)) }
            items(removedDevices) { device ->
                DeviceCard(
                    device = device,
                    isActive = false,
                    isLiveConnected = false,
                    dimmed = true,
                    onMakeActive = { switchTarget = device },
                    onRename = { renameTarget = device },
                    onRemove = null,
                    onReAdd = { switchTarget = device },
                    onDeleteData = { deleteDataTarget = device },
                )
            }
        }

        item { WhoopFirstFooter() }
    }

    // --- Add a device (guided, branching wizard: WHOOP family · HR strap · coming-soon rows) ---
    if (showAddWizard) {
        AddDeviceWizard(
            viewModel = viewModel,
            onClose = { showAddWizard = false; reload() },
            // The Oura gate's file-import links close the wizard and route to Data Sources, so the
            // non-destructive lane is always one tap away (it is never the only door).
            onUseFileImport = { showAddWizard = false; reload(); onUseFileImport() },
        )
    }

    // --- Switch confirm ---
    switchTarget?.let { device ->
        ConfirmDialog(
            title = "Als aktives Band festlegen?",
            message = "${displayName(device)} als aktives Band festlegen? Ab jetzt liefert es deine Live-Daten. " +
                "Der Verlauf von $currentActiveName bleibt unverändert. Nur neue Tage kommen von ${displayName(device)}.",
            confirmLabel = "Aktiv setzen",
            onConfirm = {
                scope.launch { viewModel.setActiveDevice(device.id); reload() }
                switchTarget = null
            },
            onDismiss = { switchTarget = null },
        )
    }

    // --- Rename ---
    renameTarget?.let { device ->
        RenameDialog(
            device = device,
            onSave = { name ->
                scope.launch { viewModel.renamePairedDevice(device.id, name); reload() }
                renameTarget = null
            },
            onDismiss = { renameTarget = null },
        )
    }

    // --- Remove confirm ---
    removeTarget?.let { device ->
        ConfirmDialog(
            title = "Dieses Gerät entfernen?",
            message = "${displayName(device)} entfernen? LLB verbindet sich nicht mehr damit. Aufgezeichnete Daten " +
                "bleiben erhalten — du kannst es jederzeit wieder hinzufügen.",
            confirmLabel = "Entfernen",
            destructive = true,
            onConfirm = {
                val wasActive = device.status == DeviceStatus.active.name
                scope.launch {
                    viewModel.archivePairedDevice(device.id)
                    devices = viewModel.pairedDevices()
                    // If the removed device was active and other paired devices remain, prompt to pick a
                    // new active one (the registry's reload demotes the active row to paired).
                    if (wasActive && devices.orEmpty().any { it.status != DeviceStatus.archived.name }) {
                        pickNewActive = true
                    }
                }
                removeTarget = null
            },
            onDismiss = { removeTarget = null },
        )
    }

    // --- Second, strongly-worded delete-data confirm (from the Removed card's secondary control) ---
    deleteDataTarget?.let { device ->
        ConfirmDialog(
            title = "Alle Daten dieses Geräts löschen?",
            message = "Löscht dauerhaft alle von ${displayName(device)} aufgezeichneten Daten. Das kann nicht rückgängig gemacht werden.",
            confirmLabel = "Daten löschen",
            destructive = true,
            onConfirm = {
                scope.launch { viewModel.deletePairedDeviceData(device.id); reload() }
                deleteDataTarget = null
            },
            onDismiss = { deleteDataTarget = null },
        )
    }

    // --- After removing the active device, offer to pick a new active one (if any remain) ---
    if (pickNewActive) {
        PickActiveDialog(
            devices = activeDevices,
            onPick = { device ->
                scope.launch { viewModel.setActiveDevice(device.id); reload() }
                pickNewActive = false
            },
            onLeaveNone = { pickNewActive = false },
        )
    }
}

// MARK: - Device card

/** One paired device as a [NoopCard]: name, brand·model, a capabilities line, a state pill, last-seen,
 *  and a per-device actions menu. The active device is tinted with the accent (WHOOP blue) and carries
 *  an "Active" pill. */
@Composable
private fun DeviceCard(
    device: PairedDeviceRow,
    isActive: Boolean,
    isLiveConnected: Boolean,
    dimmed: Boolean = false,
    /** The active+connected device's live battery percent (0–100) — surfaced the same way for WHOOP, a
     *  generic strap, or an FTMS machine. null when not active/connected or no battery was reported. */
    liveBatteryPct: Int? = null,
    /** The active+connected strap's firmware version (from the connect handshake). null when not
     *  active/connected, or for a source that reports no firmware (e.g. a non-WHOOP strap). */
    liveFirmware: String? = null,
    onMakeActive: () -> Unit,
    onRename: () -> Unit,
    onRemove: (() -> Unit)?,
    onReAdd: (() -> Unit)? = null,
    onDeleteData: (() -> Unit)? = null,
) {
    val profile = deviceProfile(device)
    // The per-device actions menu's open state is hoisted here so the WHOLE card is a tap target that opens
    // the same menu the trailing ⋮ button does — additive, non-destructive (the menu still gates every
    // action + confirm), and it gives the card a real `clickable` to drive `liquidPress`.
    var menuOpen by remember { mutableStateOf(false) }
    // liquidPress: the SAME interactionSource feeds the card's clickable and the press modifier, so the
    // whole card settles inward on press (the iOS LiquidPressStyle feel). Applied on the OUTER card so the
    // frosted surface + content scale/dim as one, matching the liquid Today cards.
    val interaction = remember { MutableInteractionSource() }
    val cardModifier = Modifier
        .alpha(if (dimmed) 0.6f else 1f)
        .liquidPress(interaction)
        .clickable(
            interactionSource = interaction,
            indication = null,
            onClickLabel = "Aktionen für ${displayName(device)}",
        ) { menuOpen = true }

    // The ACTIVE device is the hero: the liquid translucent-black frosted card (rgba(13,14,20,.80), radius
    // 26, white@0.11 hairline) so it floats over the day-of-sky, matching the liquid Today hero. Every other
    // card (paired / removed) keeps the crisp neutral NoopCard frosted surface.
    val body: @Composable () -> Unit = {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.Top,
            ) {
                Icon(
                    imageVector = deviceIcon(device),
                    contentDescription = null,
                    tint = if (isActive) Palette.accent else Palette.textSecondary,
                    modifier = Modifier.size(28.dp),
                )
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(3.dp),
                ) {
                    Text(displayName(device), style = NoopType.headline, color = Palette.textPrimary)
                    Text(profile.displayModel, style = NoopType.subhead, color = Palette.textSecondary)
                }
                // Locally-adopted Oura is Beta: a non-dot Beta chip sits beside the usual state pill.
                if (device.sourceKind == SourceKind.oura.name) {
                    StatePill("Beta", tone = StrandTone.Warning, showsDot = false)
                    Spacer(Modifier.width(6.dp))
                }
                StatePill(device, isActive, isLiveConnected)
            }

            // Honest local-takeover state row for an adopted Oura ring that is paired but not the
            // active+connected source right now. States the single-owner reality plainly (if the ring was
            // reset again or re-claimed in the Oura app, LLB no longer owns it) without faking a live
            // reading. Suppressed for the active+connected ring and for removed rings. Mirrors the macOS
            // ouraLocalStateNote.
            if (device.sourceKind == SourceKind.oura.name && !isLiveConnected &&
                device.status == DeviceStatus.paired.name
            ) {
                OuraLocalStateNote()
            }

            // What this device CAPTURES — honest, per-model (not the generic stored set, which would
            // mislabel e.g. a "Sauerstoffsättigung" chip when no SpO₂ % ever comes off the strap).
            CapabilityInfoRow(Icons.Filled.FavoriteBorder, profile.captures)
            // What LLB USES it for — the scores / screens this device drives.
            CapabilityInfoRow(Icons.Filled.Bolt, profile.powers)
            // Honest footnote: the "*" estimates + the SpO₂/steps caveats.
            if (profile.footnote.isNotEmpty()) {
                Text(profile.footnote, style = NoopType.footnote, color = Palette.textTertiary)
            }

            // Live battery as a small liquid TUBE — the active+connected device's reported % (WHOOP, a
            // generic strap or an FTMS machine all funnel into live.batteryPct). A genuine single-value
            // progress bar, so a static (posed) LiquidTube is exactly right; it replaces the "· Akku x%"
            // that used to sit in the text line below. The SAME `liveBatteryPct` binding drives it.
            if (liveBatteryPct != null) {
                BatteryTube(pct = liveBatteryPct)
            }

            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    lastSeenLine(device, isLiveConnected) +
                        (liveFirmware?.let { " · FW $it" } ?: ""),
                    style = NoopType.footnote,
                    color = Palette.textTertiary,
                    modifier = Modifier.weight(1f),
                )
                DeviceActionsMenu(
                    device = device,
                    isActive = isActive,
                    open = menuOpen,
                    onOpenChange = { menuOpen = it },
                    onMakeActive = onMakeActive,
                    onRename = onRename,
                    onRemove = onRemove,
                    onReAdd = onReAdd,
                    onDeleteData = onDeleteData,
                )
            }
        }
    }

    if (isActive) {
        Box(
            modifier = cardModifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(LIQUID_HERO_RADIUS))
                .background(LIQUID_HERO_FILL)
                .border(1.dp, Color.White.copy(alpha = 0.11f), RoundedCornerShape(LIQUID_HERO_RADIUS))
                .padding(18.dp),
        ) {
            body()
        }
    } else {
        NoopCard(
            modifier = cardModifier,
            padding = 18.dp,
        ) {
            body()
        }
    }
}

/**
 * The active+connected device's live battery as a small liquid tube. A posed (static) [LiquidTube] fills to
 * the reported percent in the accent, with a leading "Akku" label + the trailing %, so the same figure
 * that used to read as "· Akku x%" in the meta line now reads as the liquid vessel the design calls for.
 */
@Composable
private fun BatteryTube(pct: Int) {
    val clamped = pct.coerceIn(0, 100)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier.semantics { contentDescription = "Akku $clamped%" },
    ) {
        Text("Akku", style = NoopType.footnote, color = Palette.textTertiary)
        LiquidTube(
            frac = clamped / 100.0,
            tint = Palette.accent,
            animated = false,
            modifier = Modifier.weight(1f),
        )
        Text("$clamped%", style = NoopType.footnote, color = Palette.textSecondary)
    }
}

@Composable
private fun StatePill(device: PairedDeviceRow, isActive: Boolean, isLiveConnected: Boolean) {
    when {
        device.status == DeviceStatus.archived.name ->
            StatePill("Entfernt", tone = StrandTone.Neutral, showsDot = false)
        isActive ->
            StatePill(
                if (isLiveConnected) "Aktiv · Live" else "Aktiv",
                tone = StrandTone.Positive,
                pulsing = isLiveConnected,
            )
        else -> StatePill("Gekoppelt", tone = StrandTone.Neutral)
    }
}

@Composable
private fun DeviceActionsMenu(
    device: PairedDeviceRow,
    isActive: Boolean,
    // Open state is hoisted to the DeviceCard so the whole card (not just this ⋮ button) can open the menu.
    open: Boolean,
    onOpenChange: (Boolean) -> Unit,
    onMakeActive: () -> Unit,
    onRename: () -> Unit,
    onRemove: (() -> Unit)?,
    onReAdd: (() -> Unit)?,
    onDeleteData: (() -> Unit)?,
) {
    Box {
        IconButton(
            onClick = { onOpenChange(true) },
            modifier = Modifier
                .size(32.dp)
                .semantics { contentDescription = "Aktionen für ${displayName(device)}" },
        ) {
            Icon(Icons.Filled.MoreVert, contentDescription = null, tint = Palette.textSecondary, modifier = Modifier.size(20.dp))
        }
        DropdownMenu(expanded = open, onDismissRequest = { onOpenChange(false) }) {
            if (device.status == DeviceStatus.archived.name) {
                if (onReAdd != null) {
                    MenuItem("Aktiv setzen", Icons.Filled.Bolt) { onOpenChange(false); onReAdd() }
                }
                MenuItem("Umbenennen", Icons.Filled.Edit) { onOpenChange(false); onRename() }
                if (onDeleteData != null) {
                    HorizontalDivider(color = Palette.hairline)
                    MenuItem("Gerätedaten löschen…", Icons.Filled.Delete, destructive = true) {
                        onOpenChange(false); onDeleteData()
                    }
                }
            } else {
                if (!isActive) {
                    MenuItem("Aktiv setzen", Icons.Filled.Bolt) { onOpenChange(false); onMakeActive() }
                }
                MenuItem("Umbenennen", Icons.Filled.Edit) { onOpenChange(false); onRename() }
                if (onRemove != null) {
                    HorizontalDivider(color = Palette.hairline)
                    MenuItem("Entfernen", Icons.Filled.RemoveCircleOutline, destructive = true) {
                        onOpenChange(false); onRemove()
                    }
                }
            }
        }
    }
}

@Composable
private fun MenuItem(
    label: String,
    icon: ImageVector,
    destructive: Boolean = false,
    onClick: () -> Unit,
) {
    val color = if (destructive) Palette.statusCritical else Palette.textPrimary
    DropdownMenuItem(
        text = { Text(label, style = NoopType.body, color = color) },
        leadingIcon = { Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(18.dp)) },
        onClick = onClick,
    )
}

@Composable
private fun ReconnectDeviceButton(
    scanning: Boolean,
    onReconnect: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        NoopButton(
            text = if (scanning) "Suche…" else "Erneut verbinden",
            leadingIcon = Icons.Filled.Refresh,
            kind = NoopButtonKind.Primary,
            fullWidth = true,
            enabled = !scanning,
            modifier = Modifier.semantics {
                contentDescription = if (scanning) "Suche nach Band" else "Band erneut verbinden"
            },
            onClick = onReconnect,
        )
        Text(
            if (scanning) "Suche nach deinem WHOOP…"
            else "Tippen, wenn das Band nicht gefunden wird. Offizielle WHOOP-App vorher beenden.",
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

@Composable
private fun AddDeviceButton(onClick: () -> Unit) {
    // Routed through the unified NoopButton (Design Reset) so the add affordance is the crisp
    // filled-accent-blue / white-label primary the iOS DevicesView uses (`NoopButton(... kind: .primary,
    // fullWidth: true)`) — no hand-rolled gold-text fill, no glow.
    NoopButton(
        text = "Gerät hinzufügen",
        leadingIcon = Icons.Filled.Add,
        kind = NoopButtonKind.Primary,
        fullWidth = true,
        modifier = Modifier
            .padding(top = 4.dp)
            .semantics { contentDescription = "Gerät hinzufügen" },
        onClick = onClick,
    )
}

@Composable
private fun WhoopFirstFooter() {
    Row(
        modifier = Modifier.padding(top = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            Icons.Filled.FavoriteBorder,
            contentDescription = null,
            tint = Palette.textTertiary,
            modifier = Modifier.size(16.dp),
        )
        Text(
            "WHOOP ist LLBs primäres, vollständig unterstütztes Band. Andere Herzfrequenz-Gurte sind eine frühe " +
                "Erweiterung in Entwicklung: sie streamen Live-HF und HRV, aber nicht WHOOPs tiefere " +
                "Schlaf- und Erholungsdaten.",
            style = NoopType.footnote,
            color = Palette.textTertiary,
        )
    }
}

// MARK: - Shared dialogs

@Composable
private fun ConfirmDialog(
    title: String,
    message: String,
    confirmLabel: String,
    cancelLabel: String = "Abbrechen",
    destructive: Boolean = false,
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text(title, style = NoopType.title2, color = Palette.textPrimary) },
        text = { Text(message, style = NoopType.subhead, color = Palette.textSecondary) },
        confirmButton = {
            TextButton(onClick = onConfirm) {
                Text(
                    confirmLabel,
                    style = NoopType.body,
                    color = if (destructive) Palette.statusCritical else Palette.accent,
                )
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text(cancelLabel, style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

@Composable
private fun RenameDialog(
    device: PairedDeviceRow,
    onSave: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    var draft by remember { mutableStateOf(device.nickname ?: displayName(device)) }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Palette.surfaceOverlay,
        title = { Text("Gerät umbenennen", style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    "Gib ${device.brand} ${device.model} einen Namen, den du erkennst.",
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                OutlinedTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    singleLine = true,
                    placeholder = { Text("Name", style = NoopType.body, color = Palette.textTertiary) },
                    colors = devicesFieldColors(),
                    modifier = Modifier.fillMaxWidth().semantics { contentDescription = "Gerätename" },
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(draft) }) {
                Text("Speichern", style = NoopType.body, color = Palette.accent)
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Abbrechen", style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

@Composable
private fun PickActiveDialog(
    devices: List<PairedDeviceRow>,
    onPick: (PairedDeviceRow) -> Unit,
    onLeaveNone: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onLeaveNone,
        containerColor = Palette.surfaceOverlay,
        title = { Text("Neues aktives Band wählen", style = NoopType.title2, color = Palette.textPrimary) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    "Du hast dein aktives Band entfernt. Wähle, welches gekoppelte Band Live-Daten liefert, oder " +
                        "lass keines aktiv und koppeln später eines.",
                    style = NoopType.subhead,
                    color = Palette.textSecondary,
                )
                Spacer(Modifier.height(4.dp))
                devices.forEach { device ->
                    Text(
                        displayName(device),
                        style = NoopType.body,
                        color = Palette.accent,
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(8.dp))
                            .clickable { onPick(device) }
                            .padding(vertical = 10.dp),
                    )
                }
            }
        },
        confirmButton = {},
        dismissButton = {
            TextButton(onClick = onLeaveNone) {
                Text("Keines aktiv lassen", style = NoopType.body, color = Palette.textSecondary)
            }
        },
    )
}

// MARK: - Signal indicator
//
// A four-bar signal indicator derived from RSSI. RSSI is negative dBm: closer to 0 is stronger. Buckets
// are coarse on purpose — a precise dBm readout would be noise to the user. Mirrors the Swift SignalBars.

@Composable
internal fun SignalBars(rssi: Int) {
    val level = SignalBars.level(rssi)
    Row(
        verticalAlignment = Alignment.Bottom,
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        modifier = Modifier.height(18.dp),
    ) {
        for (i in 0 until 4) {
            Box(
                modifier = Modifier
                    .width(3.dp)
                    .height((6 + i * 3).dp)
                    .clip(RoundedCornerShape(1.dp))
                    .background(if (i < level) Palette.accent else Palette.hairlineStrong),
            )
        }
    }
}

internal object SignalBars {
    /** RSSI (negative dBm) → 0..4 signal level, coarse buckets. Matches the Swift SignalBars.level. */
    fun level(rssi: Int): Int = when {
        rssi >= -55 -> 4
        rssi >= -67 -> 3
        rssi >= -80 -> 2
        rssi >= -90 -> 1
        else -> 0
    }
}

// MARK: - Field colours

@Composable
private fun devicesFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedTextColor = Palette.textPrimary,
    unfocusedTextColor = Palette.textPrimary,
    cursorColor = Palette.accent,
    focusedBorderColor = Palette.accent,
    unfocusedBorderColor = Palette.hairline,
    focusedContainerColor = Palette.surfaceInset,
    unfocusedContainerColor = Palette.surfaceInset,
)

// MARK: - Presentation helpers (mirror the Swift PairedDevice computed props)

/**
 * Collapsed display name (mirrors Swift `PairedDevice.displayName`): the nickname if present, else the
 * model if it already contains the brand (so the seeded WHOOP/WHOOP reads "WHOOP", not "WHOOP WHOOP"),
 * else "brand model".
 */
internal fun displayName(device: PairedDeviceRow): String {
    device.nickname?.takeIf { it.isNotBlank() }?.let { return it }
    return if (device.model.contains(device.brand, ignoreCase = true)) device.model
    else "${device.brand} ${device.model}"
}

/** SF-Symbol-equivalent icon: WHOOP keeps the band glyph; an FTMS machine reads as gym equipment;
 *  generic straps read as a heart-rate strap. */
private fun deviceIcon(device: PairedDeviceRow): ImageVector = when {
    device.sourceKind == SourceKind.ftms.name -> Icons.AutoMirrored.Filled.DirectionsRun
    device.sourceKind == SourceKind.huami.name -> Icons.Filled.GraphicEq
    device.sourceKind == SourceKind.oura.name -> Icons.Filled.Circle
    SourceCoordinator.isWhoop(device) -> Icons.Filled.Watch
    else -> Icons.Filled.FavoriteBorder
}

/**
 * Honest, per-model capability + function summary for a device card — mirrors the Swift
 * `DeviceCapabilityProfile`. Derived from brand/model, NOT the generic stored capability set (which
 * would render an identical line for a 4.0 and a 5/MG and mislabel "Sauerstoffsättigung" when no SpO₂ % ever
 * comes off any WHOOP strap — raw red/IR only; a real % is import-only). "*" in a label = an on-device
 * estimate, not a raw sensor. Source-verified against the decode + scoring paths (capability audit).
 */
private data class DeviceCapabilityProfile(
    val displayModel: String,  // clean card subtitle (replaces the redundant "WHOOP · WHOOP")
    val captures: String,      // "·"-joined honest capture labels for THIS model
    val powers: String,        // the LLB scores / screens this device drives
    val footnote: String,      // one short honest caveat line ("*" estimates + the SpO₂/steps notes)
)

private fun deviceProfile(device: PairedDeviceRow): DeviceCapabilityProfile {
    // FTMS gym machine: a live machine + (when reported) HR session, recorded via the existing
    // live-workout path. Effort-scored only when the machine actually reports heart rate.
    if (device.sourceKind == SourceKind.ftms.name) {
        return DeviceCapabilityProfile(
            displayModel = "Fitnessgeräte (FTMS)",
            captures = "Geschwindigkeit · Kadenz · Leistung · Distanz · Energie · Herzfrequenz (falls das Gerät sie sendet)",
            powers = "Zeichnet ein Live-Geräte-Workout auf, Effort aus HF wenn das Gerät sie meldet",
            footnote = "Live-Gerätedaten über Bluetooth FTMS. Kein Schlaf, keine Erholung, keine Hauttemperatur oder SpO₂. " +
                "Effort braucht die HF des Geräts; ohne sie werden nur die Gerätemetriken protokolliert.",
        )
    }
    // EXPERIMENTAL Huami device (Amazfit / Zepp / Mi Band): best-effort live HR only, honest about it.
    if (device.sourceKind == SourceKind.huami.name) {
        return DeviceCapabilityProfile(
            displayModel = "${device.brand} (experimentell)",
            captures = "Herzfrequenz (live, best-effort)",
            powers = "Versorgt Live-Konsole + Effort. Kein Charge, Rest oder Schlaf",
            footnote = "Experimentell: Live-HF, soweit das Band sie liefert. Manche Bänder brauchen eine Kopplung, " +
                "die wir noch nicht können. LLB sagt das ehrlich und zeigt keine erfundenen Zahlen. Kein Schlaf, " +
                "keine Erholung, Hauttemperatur, SpO₂ oder Schritte.",
        )
    }
    // EXPERIMENTAL locally-adopted Oura ring (gen 3/4/5). The gen is carried on `model` ("Oura Ring
    // 3/4/5") and recovered with OuraRingGen.from(model). LLB reads the ring's OWN raw signals + open
    // HRV/sleep-phase tags and computes its own Charge/Effort/Rest; it NEVER reads Oura's encrypted
    // Readiness/Sleep scores, and claims NO absolute SpO₂ %. Estimates carry "*"; a signal it can't read
    // stays "-". Per-gen copy + the canonical Beta caveat (spec
    // docs/superpowers/specs/2026-06-29-oura-onboarding-ux.md s3/s4). Mirrors the macOS Oura branch.
    if (device.sourceKind == SourceKind.oura.name) {
        val gen = com.noop.oura.OuraRingGen.from(device.model)
        // gen3/4 are verified-shape; gen5 ("newer") carries the least-proven caveat.
        val newer = gen == com.noop.oura.OuraRingGen.GEN5
        val captures = if (newer)
            "Herzfrequenz* · HRV* · Schlaf* · Ruhe-HF* · Hauttemp.* · Akku*"
        else
            "Herzfrequenz · HRV* · Schlaf · Ruhe-HF · Hauttemp.* · Akku"
        val powers = if (newer)
            "Versorgt Effort jetzt; Charge und Rest, sobald genug Nächte und Decode bestätigt sind"
        else
            "Versorgt Charge, Effort, Rest und Schlaf"
        return DeviceCapabilityProfile(
            displayModel = "${gen.displayName} (Beta)",
            captures = captures,
            powers = powers,
            footnote = "Beta. * = Schätzung auf dem Gerät. Hauttemp. ist ein Trend zur eigenen Baseline, " +
                "HRV braucht Ruhe. Keine Oura-Bereitschaft oder SpO₂-% " +
                "vom Ring (dafür Oura-Datei importieren).",
        )
    }
    // Generic heart-rate strap: live HR + R-R only; drives the live console + Effort, nothing nightly.
    if (!SourceCoordinator.isWhoop(device)) {
        return DeviceCapabilityProfile(
            displayModel = "Herzfrequenz-Gurt",
            captures = "Herzfrequenz · HRV (live)* · Strain",
            powers = "Versorgt Live-Konsole + Effort. Kein Charge, Rest oder Schlaf",
            footnote = "Nur Live-HF + R-R · kein Schlaf, keine Erholung, Hauttemp., SpO₂, Schritte oder Akku " +
                "(das ist WHOOP-only).",
        )
    }
    val whoopPowers = "Versorgt Charge, Effort, Rest, Schlaf + Gesundheitsmonitor"
    val model = device.model.lowercase()
    // WHOOP 5.0 / MG — adds a (raw) step count the 4.0 can't read over BLE.
    if (model.contains("5") || model.contains("mg")) {
        return DeviceCapabilityProfile(
            displayModel = "WHOOP 5.0 / MG",
            captures = "Herzfrequenz · HRV · Hauttemp.* · Atemfreq.* · Schritte* · Schlaf · Strain · Akku",
            powers = whoopPowers,
            footnote = "* Schätzung auf dem Gerät: Hauttemp. ist nächtliche ±°C-Abweichung, Schritte ein roher " +
                "Bewegungszähler (#78). Kein SpO₂-% vom Band; für echte % WHOOP-CSV importieren.",
        )
    }
    // WHOOP 4.0 — LLB's primary band; no steps over BLE.
    if (model.contains("4")) {
        return DeviceCapabilityProfile(
            displayModel = "WHOOP 4.0",
            captures = "Herzfrequenz · HRV · Hauttemp.* · Atemfreq.* · Schlaf · Strain · Akku",
            powers = whoopPowers,
            footnote = "* Schätzung auf dem Gerät: Hauttemp. ist nächtliche ±°C-Abweichung (firmwareabhängig); " +
                "keine Schritte über BLE beim 4.0. Kein SpO₂-% vom Band; für echte % WHOOP-CSV importieren.",
        )
    }
    // Legacy / unknown WHOOP (the seeded device, model just "WHOOP") — show only the common-to-all set.
    return DeviceCapabilityProfile(
        displayModel = "WHOOP",
        captures = "Herzfrequenz · HRV · Hauttemp.* · Atemfreq.* · Schlaf · Strain · Akku",
        powers = whoopPowers,
        footnote = "Genaues Modell unbekannt. Zeigt, was jedes WHOOP kann. * Schätzung auf dem Gerät · " +
            "kein SpO₂-% vom Band (dafür WHOOP-CSV importieren).",
    )
}

/** One icon-prefixed info row (captures / powers) for a device card, matching the caption style. */
@Composable
private fun CapabilityInfoRow(icon: androidx.compose.ui.graphics.vector.ImageVector, text: String) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(icon, contentDescription = null, tint = Palette.textTertiary, modifier = Modifier.size(14.dp))
        Text(text, style = NoopType.caption, color = Palette.textSecondary)
    }
}

/**
 * Honest paired-but-not-connected note for a locally-adopted Oura ring (Beta). Amber heads-up, no
 * fabricated reading: re-states the single-owner reality so the user understands why a re-reset or an Oura
 * re-claim would break LLB's ownership. Mirrors the macOS DeviceCard.ouraLocalStateNote (no em-dashes).
 */
@Composable
private fun OuraLocalStateNote() {
    Row(
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.Info, contentDescription = null, tint = Palette.statusWarning, modifier = Modifier.size(14.dp))
        Text(
            "Lokal gekoppelt. LLB besitzt diesen Ring, solange es den Schlüssel hält. Wenn du ihn erneut zurücksetzt oder " +
                "in der Oura-App einrichtest, besitzt LLB ihn nicht mehr — dann erneut hinzufügen.",
            style = NoopType.caption,
            color = Palette.statusWarning,
        )
    }
}

private fun lastSeenLine(device: PairedDeviceRow, isLiveConnected: Boolean): String = when {
    device.status == DeviceStatus.archived.name -> "Entfernt · Daten behalten"
    isLiveConnected -> "Jetzt verbunden"
    else -> "Zuletzt gesehen ${relativeAgo(device.lastSeenAt)}"
}

/** Best-effort brand from the advertised name. Falls back to a neutral label. Mirrors Swift brandGuess. */
internal fun brandGuess(name: String): String {
    val lower = name.lowercase()
    return when {
        lower.contains("polar") -> "Polar"
        lower.contains("wahoo") || lower.contains("tickr") -> "Wahoo"
        lower.contains("coospo") -> "Coospo"
        lower.contains("garmin") || lower.contains("hrm") -> "Garmin"
        lower.contains("scosche") || lower.contains("rhythm") -> "Scosche"
        lower.contains("magene") -> "Magene"
        lower.contains("amazfit") || lower.contains("helio") || lower.contains("zepp") -> "Amazfit"
        else -> "Herzfrequenz-Gurt"
    }
}
