package cloud.anj.anj_cloud

import android.content.Context
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

/// One process, one engine (spec #28 What Android Is). The Application owns a single
/// cached FlutterEngine running the Dart entry point, which runs the existing sync worker
/// isolate. The activity attaches to it, and the later WorkManager worker (A4),
/// foreground service (A4), DocumentsProvider (A5) and updater (A7) attach to the same
/// engine; none of them starts a second one, which keeps spec #3's single writer. The
/// profile flock in app-private storage backs this up across processes.
object SyncHost {
    const val ENGINE_ID = "anj-sync-host"

    @Synchronized
    fun engine(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ENGINE_ID)?.let { return it }
        val app = context.applicationContext
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(app)
        loader.ensureInitializationComplete(app, null)
        val engine = FlutterEngine(app)
        DeviceChannel.register(app, engine.dartExecutor.binaryMessenger)
        // Before the entry point runs, so a background run that started the process finds it.
        BackgroundChannel.install(app, engine)
        UpdateChannel.register(app, engine)
        // The documents provider's and "Apps with access" channels (spec #28 A5), listening
        // before the Dart entry starts.
        DocumentsBridge.attach(app, engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
        return engine
    }
}
