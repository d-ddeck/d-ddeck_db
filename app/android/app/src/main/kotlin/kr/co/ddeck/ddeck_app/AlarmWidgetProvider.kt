package kr.co.ddeck.ddeck_app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import org.json.JSONObject
import java.time.Instant
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Reads the same durable snapshot as SyncedAlarmStore (legacy shared_preferences).
 * No credentials, server requests or Flutter engine are needed by the launcher. */
object AlarmWidgetData {
    fun snapshot(context: Context): JSONObject = try {
        JSONObject(context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getString("flutter.calendar_alarm.synced", "{}") ?: "{}")
    } catch (_: Exception) { JSONObject() }

    fun upcoming(context: Context): List<JSONObject> {
        val reminders = snapshot(context).optJSONArray("reminders") ?: return emptyList()
        val now = System.currentTimeMillis()
        return (0 until reminders.length()).mapNotNull { reminders.optJSONObject(it) }
            .filter { instant(it.optString("scheduled_at")) > now }
            .sortedBy { instant(it.optString("scheduled_at")) }
            .take(50)
    }

    fun instant(raw: String): Long = try { Instant.parse(raw).toEpochMilli() } catch (_: Exception) { 0L }
    fun date(raw: String): String = if (instant(raw) == 0L) "없음" else
        SimpleDateFormat("M/d HH:mm", Locale.KOREA).format(Date(instant(raw)))

    fun row(context: Context, item: JSONObject): RemoteViews =
        RemoteViews(context.packageName, R.layout.alarm_widget_row).apply {
            setTextViewText(R.id.alarm_title, item.optString("title").take(160))
            setTextViewText(R.id.alarm_time, date(item.optString("scheduled_at")) + " 알람")
            val place = item.optString("location", "").takeUnless { it == "null" }.orEmpty()
            val calendar = item.optString("calendar_name", "").takeUnless { it == "null" }.orEmpty()
            setTextViewText(R.id.alarm_place, listOf(calendar, place).filter { it.isNotBlank() }.joinToString(" · ").take(160))
            setOnClickFillInIntent(R.id.alarm_row, Intent().putExtra("reminder_id", item.optString("reminder_id")))
        }
}

class AlarmWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) = update(context, ids)
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) = update(context, intArrayOf(id))
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action in listOf(REFRESH, Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED, Intent.ACTION_MY_PACKAGE_REPLACED)) updateAll(context)
    }

    companion object {
        const val OPEN = "kr.co.ddeck.ddeck_app.OPEN_ALARMS"
        const val REFRESH = "kr.co.ddeck.ddeck_app.REFRESH_ALARMS"
        fun updateAll(context: Context) = update(context, AppWidgetManager.getInstance(context)
            .getAppWidgetIds(ComponentName(context, AlarmWidgetProvider::class.java)))

        @Suppress("DEPRECATION")
        private fun update(context: Context, ids: IntArray) {
            val manager = AppWidgetManager.getInstance(context)
            val items = AlarmWidgetData.upcoming(context)
            for (id in ids) {
                val views = RemoteViews(context.packageName, R.layout.alarm_widget)
                views.setTextViewText(R.id.alarm_updated, "저장: " + AlarmWidgetData.date(AlarmWidgetData.snapshot(context).optString("synced_at")))
                views.setEmptyView(R.id.alarm_list, R.id.alarm_empty)
                if (Build.VERSION.SDK_INT >= 31) {
                    val collection = RemoteViews.RemoteCollectionItems.Builder().setViewTypeCount(1)
                    items.forEachIndexed { index, item -> collection.addItem(index.toLong(), AlarmWidgetData.row(context, item)) }
                    views.setRemoteAdapter(R.id.alarm_list, collection.build())
                } else {
                    val service = Intent(context, AlarmWidgetService::class.java).apply {
                        data = Uri.parse("ddeck-widget://list/$id")
                    }
                    views.setRemoteAdapter(R.id.alarm_list, service)
                }
                val open = Intent(context, MainActivity::class.java).apply {
                    action = OPEN
                    flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                    data = Uri.parse("ddeck-widget://open/$id")
                }
                val mutable = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
                views.setPendingIntentTemplate(R.id.alarm_list, PendingIntent.getActivity(context, id, open, PendingIntent.FLAG_UPDATE_CURRENT or mutable))
                views.setOnClickPendingIntent(R.id.alarm_heading, PendingIntent.getActivity(context, id + 100000, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
                val refresh = Intent(context, AlarmWidgetProvider::class.java).setAction(REFRESH)
                views.setOnClickPendingIntent(R.id.alarm_refresh, PendingIntent.getBroadcast(context, 0, refresh, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
                manager.updateAppWidget(id, views)
                if (Build.VERSION.SDK_INT < 31) manager.notifyAppWidgetViewDataChanged(id, R.id.alarm_list)
            }
        }
    }
}

class AlarmWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory = object : RemoteViewsFactory {
        private var items = emptyList<JSONObject>()
        override fun onCreate() { onDataSetChanged() }
        override fun onDataSetChanged() { items = AlarmWidgetData.upcoming(applicationContext) }
        override fun onDestroy() { items = emptyList() }
        override fun getCount() = items.size
        override fun getViewAt(position: Int): RemoteViews? = items.getOrNull(position)?.let { AlarmWidgetData.row(applicationContext, it) }
        override fun getLoadingView(): RemoteViews? = null
        override fun getViewTypeCount() = 1
        override fun getItemId(position: Int) = position.toLong()
        override fun hasStableIds() = false
    }
}
