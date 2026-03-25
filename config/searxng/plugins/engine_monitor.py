import logging
import threading

from searx.plugins import Plugin, PluginInfo

logger = logging.getLogger("searx.plugins.engine_monitor")

EXPECTED_ENGINES = {"google"}
GENERAL_ENGINES = {"google", "marginalia", "duckduckgo", "brave"}
MIN_OTHER_ENGINES = 2
CONSECUTIVE_THRESHOLD = 5


class SXNGPlugin(Plugin):
    id = "engine_monitor"
    active = True

    def __init__(self, plg_cfg):
        super().__init__(plg_cfg)
        self.info = PluginInfo(
            id=self.id,
            name="Engine Monitor",
            description="Logs when expected engines are missing from search results",
            preference_section="general",
        )
        self.consecutive_misses = {}
        self.lock = threading.Lock()

    def on_result(self, request, search, result):
        if not hasattr(request, "_monitor_engines"):
            request._monitor_engines = set()
        engine = getattr(result, "engine", "")
        if engine:
            request._monitor_engines.add(engine)
        return True

    def post_search(self, request, search):
        seen = getattr(request, "_monitor_engines", set())

        # Only monitor general searches — if fewer than 2 non-monitored
        # general engines returned results, this wasn't a general search
        other_general = (seen & GENERAL_ENGINES) - EXPECTED_ENGINES
        if len(other_general) < MIN_OTHER_ENGINES:
            return None

        with self.lock:
            for engine in EXPECTED_ENGINES:
                if engine in seen:
                    if self.consecutive_misses.get(engine, 0) > 0:
                        logger.info(
                            "Engine '%s' recovered after %d consecutive misses",
                            engine,
                            self.consecutive_misses[engine],
                        )
                    self.consecutive_misses[engine] = 0
                else:
                    count = self.consecutive_misses.get(engine, 0) + 1
                    self.consecutive_misses[engine] = count
                    if count >= CONSECUTIVE_THRESHOLD:
                        logger.error(
                            "Engine '%s' missing from results for %d consecutive searches",
                            engine,
                            count,
                        )
                    else:
                        logger.warning(
                            "Engine '%s' missing from results (%d/%d)",
                            engine,
                            count,
                            CONSECUTIVE_THRESHOLD,
                        )

        return None
