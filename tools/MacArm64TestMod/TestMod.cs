using MelonLoader;

[assembly: MelonInfo(typeof(MacArm64TestMod.TestMod), "MacArm64TestMod", "1.0.0", "Author")]
[assembly: MelonGame("Ninja Kiwi", "BloonsTD6")]

namespace MacArm64TestMod
{
    public class TestMod : MelonMod
    {
        private const int ReportFrame = 100;
        private const int ProbeRetryFrames = 30;
        private int _frameCount;
        private bool _shortHookProbeRan;

        public override void OnInitializeMelon()
        {
            LoggerInstance.Msg("[TEST MOD] Successfully initialized on macOS ARM64!");
        }

        public override void OnSceneWasLoaded(int buildIndex, string sceneName)
        {
            LoggerInstance.Msg("[TEST MOD] Scene loaded: " + sceneName);
        }

        public override void OnUpdate()
        {
            _frameCount++;
            if (_frameCount == ReportFrame)
                LoggerInstance.Msg("[TEST MOD] Frame update tick verified!");

            // Runs as soon as the game has a player, so it doesn't depend on getting past the title screen
            if (!_shortHookProbeRan && _frameCount % ProbeRetryFrames == 0)
                _shortHookProbeRan = GamePatches.TryRunShortHookProbe();
        }
    }
}
