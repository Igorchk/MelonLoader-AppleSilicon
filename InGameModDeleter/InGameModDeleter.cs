using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using BTD_Mod_Helper;
using BTD_Mod_Helper.Api.Components;
using BTD_Mod_Helper.Api.Enums;
using BTD_Mod_Helper.Extensions;
using HarmonyLib;
using Il2CppAssets.Scripts.Unity.UI_New.Popups;
using MelonLoader;
using UnityEngine;

[assembly: MelonInfo(typeof(InGameModDeleter.InGameModDeleterMod), "InGameModDeleter", "1.0.0", "Igorchk")]
[assembly: MelonGame("Ninja Kiwi", "BloonsTD6")]
[assembly: MelonAdditionalDependencies("BloonsTD6 Mod Helper")]

namespace InGameModDeleter
{
    // Adds a delete button for loaded mods to BTD6 Mod Helper's Mods menu. Mod Helper's own delete button only
    // appears for mods that are disabled and were never loaded this session, so deleting a mod normally takes
    // Disable, a restart, then Delete.
    public class InGameModDeleterMod : MelonMod
    {
        public override void OnInitializeMelon()
        {
            var missing = DeleteLoadedModButton.FindMissingModHelperMembers();
            if (missing.Count > 0)
                LoggerInstance.Error("This Mod Helper version doesn't have " + string.Join(", ", missing) +
                                     "; the delete button won't appear");
            else
                LoggerInstance.Msg("Ready: loaded mods get a delete button in Mod Helper's Mods menu");
        }
    }

    // ModsMenu.SetSelectedMod runs whenever a mod is picked in the list, and decides which of the selected mod's
    // buttons are visible. ModsMenu and ModHelperData are internal to Mod Helper, so they're reached by name.
    [HarmonyPatch]
    internal static class ModsMenuSetSelectedModPatch
    {
        private static MethodBase TargetMethod() => DeleteLoadedModButton.SetSelectedModMethod;

        [HarmonyPostfix]
        private static void Postfix(object __0) => DeleteLoadedModButton.Refresh(__0);
    }

    internal static class DeleteLoadedModButton
    {
        // Mod Helper's square buttons in the selected mod's row are ModsMenu.ModPanelHeight (200) wide, with
        // ModsMenu.Padding (50) between elements. The Settings button and Mod Helper's own delete button share the
        // right-hand slot, so this one goes one slot to the left of it
        private const float ButtonSize = 200;
        private const float Gap = 50;
        private const string DeletedMessage =
            "Mod deleted from disk. Due to Unity engine limitations, the mod will remain active in memory until you restart the game.";

        // Looked up in Mod Helper's own assembly: its Updater Plugin compiles part of ModHelperData into itself, so a
        // search of every loaded assembly by name (AccessTools.TypeByName) can find that copy, which has no Mod or
        // Enabled property, because plugins load before mods
        private static readonly Assembly ModHelperAssembly = typeof(ModHelper).Assembly;
        private static readonly Type ModsMenuType = ModHelperAssembly.GetType("BTD_Mod_Helper.UI.Menus.ModsMenu");
        internal static readonly MethodInfo SetSelectedModMethod = AccessTools.Method(ModsMenuType, "SetSelectedMod");
        private static readonly FieldInfo ModHelperDeleteButtonField = AccessTools.Field(ModsMenuType, "selectedModDeleteButton");
        private static readonly Type ModHelperDataType = ModHelperAssembly.GetType("BTD_Mod_Helper.Api.Data.ModHelperData");
        private static readonly PropertyInfo ModProperty = AccessTools.Property(ModHelperDataType, "Mod");
        private static readonly PropertyInfo EnabledProperty = AccessTools.Property(ModHelperDataType, "Enabled");
        private static readonly PropertyInfo DataDirectoryProperty = AccessTools.Property(typeof(ModHelper), "DataDirectory");

        // Files already deleted this session; their mods stay loaded and listed until the game restarts
        private static readonly HashSet<string> Deleted = new(StringComparer.OrdinalIgnoreCase);

        private static ModHelperButton button;
        private static MelonBase selectedMod;

        // The Mod Helper internals this relies on, by the names they have in 3.6.10
        internal static List<string> FindMissingModHelperMembers()
        {
            var missing = new List<string>();
            if (SetSelectedModMethod == null)
                missing.Add("ModsMenu.SetSelectedMod");
            if (ModHelperDeleteButtonField == null)
                missing.Add("ModsMenu.selectedModDeleteButton");
            if (ModProperty == null)
                missing.Add("ModHelperData.Mod");
            if (EnabledProperty == null)
                missing.Add("ModHelperData.Enabled");
            return missing;
        }

        internal static void Refresh(object modHelperData)
        {
            // Already reported once at startup by FindMissingModHelperMembers
            if (ModProperty == null || EnabledProperty == null || ModHelperDeleteButtonField == null)
                return;

            try
            {
                var mod = ModProperty.GetValue(modHelperData) as MelonBase;
                var enabled = (bool)EnabledProperty.GetValue(modHelperData);
                var path = mod?.MelonAssembly?.Location;

                // Only mods running from an enabled file. Mod Helper itself is excluded: deleting it from its own
                // menu would leave every mod that depends on it broken. A mod disabled this session has already
                // been moved to Mods/Disabled, which Mod Helper's own delete button handles after a restart
                bool show = mod != null && enabled && !IsModHelper(mod) && !string.IsNullOrEmpty(path) &&
                            !Deleted.Contains(path) && File.Exists(path);

                selectedMod = show ? mod : null;
                if (show)
                    EnsureButton();
                if (button != null)
                    button.SetActive(show);
            }
            catch (Exception e)
            {
                Melon<InGameModDeleterMod>.Logger.Error("Couldn't update the delete button", e);
            }
        }

        private static bool IsModHelper(MelonBase mod) => mod.MelonAssembly.Assembly == typeof(ModHelper).Assembly;

        // The Mods menu is rebuilt every time it opens, so the button is recreated whenever its row has changed
        private static void EnsureButton()
        {
            var modHelperButton = ModHelperDeleteButtonField.GetValue(null) as ModHelperButton;
            if (modHelperButton == null)
                return;

            var row = modHelperButton.transform.parent;
            if (button != null && button.transform.parent == row)
                return;

            button = ModHelperButton.Create(
                new Info("DeleteLoadedMod", -(ButtonSize * 1.5f + Gap), 0, ButtonSize, ButtonSize, new Vector2(1, 0.5f)),
                VanillaSprites.CloseBtn, new Action(ConfirmDelete));
            button.SetParent(row);
        }

        private static void ConfirmDelete()
        {
            var mod = selectedMod;
            if (mod == null)
                return;

            var fileName = Path.GetFileName(mod.MelonAssembly.Location);
            PopupScreen.instance.SafelyQueue(screen => screen.ShowPopup(PopupScreen.Placement.menuCenter,
                "Delete Mod",
                $"Delete {mod.Info.Name}? This removes {fileName} from your Mods folder and can't be undone. " +
                "The mod keeps running until you restart the game.",
                new Action(() => Delete(mod)), "Delete", null, "Cancel", Popup.TransitionAnim.Scale));
        }

        private static void Delete(MelonBase mod)
        {
            var path = mod.MelonAssembly.Location;
            try
            {
                // macOS removes the directory entry while the game keeps its mapping of the loaded assembly, so the
                // mod goes on working until the restart. Windows refuses to delete a loaded assembly, which lands in
                // the catch below
                File.Delete(path);
                DeleteModHelperCache(Path.GetFileName(path));

                Deleted.Add(path);
                // Unity's == also catches a button destroyed along with a closed menu
                if (selectedMod == mod && button != null)
                    button.SetActive(false);

                Melon<InGameModDeleterMod>.Logger.Msg($"Deleted {mod.Info.Name} ({path})");
                PopupScreen.instance.SafelyQueue(screen => screen.ShowOkPopup(DeletedMessage));
            }
            catch (Exception e)
            {
                Melon<InGameModDeleterMod>.Logger.Error($"Failed to delete {path}", e);
                PopupScreen.instance.SafelyQueue(screen =>
                    screen.ShowOkPopup($"Couldn't delete {Path.GetFileName(path)}: {e.Message}"));
            }
        }

        // Mod Helper caches each mod's info and icon in its Data folder, keyed by file name; its own delete removes
        // them too
        private static void DeleteModHelperCache(string dllName)
        {
            if (DataDirectoryProperty?.GetValue(null) is not string dataDirectory)
                return;

            foreach (var extension in new[] { ".json", ".png" })
            {
                var cached = Path.Combine(dataDirectory, Path.ChangeExtension(dllName, extension));
                if (File.Exists(cached))
                    File.Delete(cached);
            }
        }
    }
}
