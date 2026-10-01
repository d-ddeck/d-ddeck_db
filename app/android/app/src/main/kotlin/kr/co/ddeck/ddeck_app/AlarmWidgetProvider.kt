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
import java.time.LocalDate
import java.time.ZoneId
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Reads the durable calendar snapshot (legacy shared_preferences).
 * No credentials, server requests or Flutter engine are needed by the launcher. */
object AlarmWidgetData {
    fun snapshot(context: Context): JSONObject = try {
        JSONObject(context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getString("flutter.calendar_widget.synced", "{}") ?: "{}")
    } catch (_: Exception) { JSONObject() }

    fun selected(context: Context): LocalDate {
        val today = LocalDate.now()
        val raw = context.getSharedPreferences("ddeck_widget", Context.MODE_PRIVATE).getString("day", "")
        val day = try { LocalDate.parse(raw) } catch (_: Exception) { today }
        return if (day.year == today.year && day.month == today.month) day else today
    }

    fun events(context: Context): List<JSONObject> {
        val events = snapshot(context).optJSONArray("events") ?: return emptyList()
        return (0 until events.length()).mapNotNull { events.optJSONObject(it) }
    }

    fun overlaps(item: JSONObject, day: LocalDate): Boolean {
        val zone = ZoneId.systemDefault()
        val from = day.atStartOfDay(zone).toInstant().toEpochMilli()
        val to = day.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
        return instant(item.optString("starts_at")) < to && instant(item.optString("ends_at")) > from
    }

    fun upcoming(context: Context): List<JSONObject> = events(context)
        .filter { overlaps(it, selected(context)) }
        .sortedBy { instant(it.optString("starts_at")) }

    fun instant(raw: String): Long = try { Instant.parse(raw).toEpochMilli() } catch (_: Exception) { 0L }
    fun date(raw: String): String = if (instant(raw) == 0L) "없음" else
        SimpleDateFormat("M/d HH:mm", Locale.KOREA).format(Date(instant(raw)))

    fun row(context: Context, item: JSONObject): RemoteViews =
        RemoteViews(context.packageName, R.layout.alarm_widget_row).apply {
            setTextViewText(R.id.alarm_title, item.optString("title").take(160))
            setTextViewText(R.id.alarm_time, if (item.optBoolean("all_day")) "종일" else date(item.optString("starts_at")) + " 시작")
            val place = item.optString("location", "").takeUnless { it == "null" }.orEmpty()
            val calendar = item.optString("calendar_name", "").takeUnless { it == "null" }.orEmpty()
            setTextViewText(R.id.alarm_place, listOf(calendar, place).filter { it.isNotBlank() }.joinToString(" · ").take(160))
            setOnClickFillInIntent(R.id.alarm_row, Intent().putExtra("reminder_id", "calendar:" + item.optString("event_id")))
        }
}

class AlarmWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) = update(context, ids)
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) = update(context, intArrayOf(id))
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == SELECT) {
            val day = intent.getStringExtra("day") ?: return
            try { LocalDate.parse(day) } catch (_: Exception) { return }
            context.getSharedPreferences("ddeck_widget", Context.MODE_PRIVATE).edit().putString("day", day).apply()
            updateAll(context)
        }
        if (intent.action in listOf(REFRESH, Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED, Intent.ACTION_MY_PACKAGE_REPLACED)) updateAll(context)
    }

    companion object {
        const val SELECT = "kr.co.ddeck.ddeck_app.SELECT_WIDGET_DAY"
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
                val today = LocalDate.now()
                val selected = AlarmWidgetData.selected(context)
                views.setTextViewText(R.id.alarm_heading, "${today.year}년 ${today.monthValue}월")
                views.setTextViewText(R.id.alarm_selected, "${selected.monthValue}/${selected.dayOfMonth} 일정")
                val first = today.withDayOfMonth(1)
                val start = first.minusDays((first.dayOfWeek.value % 7).toLong())
                val events = AlarmWidgetData.events(context)
                val dayIds = intArrayOf(R.id.calendar_day_0, R.id.calendar_day_1, R.id.calendar_day_2, R.id.calendar_day_3, R.id.calendar_day_4, R.id.calendar_day_5, R.id.calendar_day_6, R.id.calendar_day_7, R.id.calendar_day_8, R.id.calendar_day_9, R.id.calendar_day_10, R.id.calendar_day_11, R.id.calendar_day_12, R.id.calendar_day_13, R.id.calendar_day_14, R.id.calendar_day_15, R.id.calendar_day_16, R.id.calendar_day_17, R.id.calendar_day_18, R.id.calendar_day_19, R.id.calendar_day_20, R.id.calendar_day_21, R.id.calendar_day_22, R.id.calendar_day_23, R.id.calendar_day_24, R.id.calendar_day_25, R.id.calendar_day_26, R.id.calendar_day_27, R.id.calendar_day_28, R.id.calendar_day_29, R.id.calendar_day_30, R.id.calendar_day_31, R.id.calendar_day_32, R.id.calendar_day_33, R.id.calendar_day_34, R.id.calendar_day_35, R.id.calendar_day_36, R.id.calendar_day_37, R.id.calendar_day_38, R.id.calendar_day_39, R.id.calendar_day_40, R.id.calendar_day_41)
                for (i in dayIds.indices) {
                    val day = start.plusDays(i.toLong())
                    val inMonth = day.month == today.month
                    val marker = if (events.any { AlarmWidgetData.overlaps(it, day) }) "·" else ""
                    views.setTextViewText(dayIds[i], if (inMonth) "${day.dayOfMonth}$marker" else "")
                    views.setInt(dayIds[i], "setBackgroundColor", if (day == selected) 0x334488FF else 0x00000000)
                    val select = Intent(context, AlarmWidgetProvider::class.java).apply {
                        action = SELECT
                        data = Uri.parse("ddeck-widget://day/$id/$i")
                        putExtra("day", (if (inMonth) day else selected).toString())
                    }
                    views.setOnClickPendingIntent(dayIds[i], PendingIntent.getBroadcast(context, id * 100 + i, select, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
                }
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
                val refresh = Intent(open).putExtra("reminder_id", "calendar:refresh").setData(Uri.parse("ddeck-widget://refresh/$id"))
                views.setOnClickPendingIntent(R.id.alarm_heading, PendingIntent.getActivity(context, id + 100000, refresh, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
                views.setOnClickPendingIntent(R.id.alarm_refresh, PendingIntent.getActivity(context, id + 100000, refresh, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
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
