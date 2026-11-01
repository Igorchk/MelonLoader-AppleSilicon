using HarmonyLib;
using Il2CppAssets.Scripts.Unity.Scenes;
using Il2CppAssets.Scripts.Models.Profile;
using Il2CppAssets.Scripts.Unity;
using Il2CppAssets.Scripts.Unity.Player;
using Il2CppAssets.Scripts.Unity.UI_New.Main;
using Il2CppSystem.Runtime.Serialization;
using MelonLoader;

namespace MacArm64TestMod
{
    // MelonLoader applies these automatically when the mod loads. One Unity message called by the engine,
    // one regular game method called by game code, so both kinds of call into a detoured IL2CPP method get covered.
    internal static class GamePatches
    {
        private const string PatchMessage = "[TEST MOD] Harmony patch successfully intercepted and executed on Apple Silicon!";

        [HarmonyPatch(typeof(TitleScreen), nameof(TitleScreen.Start))]
        internal static class TitleScreenStartPatch
        {
            [HarmonyPostfix]
            private static void Postfix() => Melon<TestMod>.Logger.Msg(PatchMessage + " (TitleScreen.Start)");
        }

        [HarmonyPatch(typeof(MainMenu), nameof(MainMenu.Open))]
        internal static class MainMenuOpenPatch
        {
            [HarmonyPostfix]
            private static void Postfix()
            {
                Melon<TestMod>.Logger.Msg(PatchMessage + " (MainMenu.Open)");

                // Call a patched method with a context whose fields are all non-zero, so a correct trampoline is
                // distinguishable from one that reads zeros or garbage. The call goes through IL2CPP's own invoker
                try
                {
                    var probe = new StreamingContext(StreamingContextStates.Clone, new Il2CppSystem.String(Il2CppInterop.Runtime.IL2CPP.ManagedStringToIl2Cpp(ProbeContext)));
                    new MapInfo().OnDeserializedMethod(probe);
                }
                catch (System.Exception e)
                {
                    Melon<TestMod>.Logger.Msg("[TEST MOD] MapInfo.OnDeserializedMethod probe threw after the prefix: " + e.GetType().Name);
                }
            }
        }

        // Btd6Player.Save is 12 bytes and Btd6Player.Sync starts right after it. A 16-byte ARM64 hook on Save
        // (this mod's patch below, and Mod Helper's) overwrites Sync's first instruction, so calling Sync raises
        // SIGILL straight away instead of at the first round end. Both only set a flag on the player.
        // Returns false while there's no player yet, so the caller can retry
        internal static bool TryRunShortHookProbe()
        {
            Btd6Player player;
            try
            {
                player = Game.Player;
            }
            catch
            {
                return false;
            }
            if (player == null)
                return false;

            Melon<TestMod>.Logger.Msg("[TEST MOD] Short-hook probe: calling Btd6Player.Save");
            player.Save();
            Melon<TestMod>.Logger.Msg("[TEST MOD] Short-hook probe: calling Btd6Player.Sync, the function a 16-byte hook on Save overwrites");
            player.Sync();
            Melon<TestMod>.Logger.Msg("[TEST MOD] Short-hook probe: Btd6Player.Sync returned normally");
            return true;
        }

        [HarmonyPatch(typeof(Btd6Player), nameof(Btd6Player.Save))]
        internal static class Btd6PlayerSavePatch
        {
            [HarmonyPrefix]
            private static void Prefix() => Melon<TestMod>.Logger.Msg("[TEST MOD] Btd6Player.Save prefix ran (the short hook is live)");
        }

        private const string ProbeContext = "arm64-probe";

        private static string Describe(StreamingContext context) =>
            $"State={(int)context.State} ({context.State}), Context={(context.Context == null ? "null" : context.Context.ToString())}";

        // [OnDeserialized] callbacks take a 16-byte StreamingContext by value, which ARM64 passes in two registers.
        // First-priority prefixes, so they still run when another mod's prefix on the same method throws
        [HarmonyPatch(typeof(ProfileModel), nameof(ProfileModel.Validate))]
        internal static class ProfileModelValidatePatch
        {
            [HarmonyPrefix]
            [HarmonyPriority(Priority.First)]
            private static void Prefix(StreamingContext __0) =>
                Melon<TestMod>.Logger.Msg("[TEST MOD] ProfileModel.Validate received StreamingContext by value: " + Describe(__0));
        }

        [HarmonyPatch(typeof(MapInfo), nameof(MapInfo.OnDeserializedMethod))]
        internal static class MapInfoOnDeserializedPatch
        {
            [HarmonyPrefix]
            [HarmonyPriority(Priority.First)]
            private static void Prefix(StreamingContext __0)
            {
                // The game calls this for every map it deserializes; only report the probe and the first real call
                var isProbe = __0.Context != null && __0.Context.ToString() == ProbeContext;
                if (isProbe || !_loggedRealMapInfoCall)
                {
                    _loggedRealMapInfoCall |= !isProbe;
                    Melon<TestMod>.Logger.Msg($"[TEST MOD] MapInfo.OnDeserializedMethod {(isProbe ? "PROBE" : "game call")}: " + Describe(__0) +
                        (isProbe ? $" (expected State={(int)StreamingContextStates.Clone}, Context={ProbeContext})" : ""));
                }
            }

            private static bool _loggedRealMapInfoCall;
        }
    }
}
