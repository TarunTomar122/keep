package com.clippy.clippy_companion

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.graphics.BitmapFactory
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Shows the most recent Keep moment as a home-screen photo frame. Corner
 * rounding comes from the layout's `clipToOutline`, not a bitmap crop.
 */
class LatestMomentWidgetProvider : HomeWidgetProvider() {

  override fun onUpdate(
      context: Context,
      appWidgetManager: AppWidgetManager,
      appWidgetIds: IntArray,
      widgetData: SharedPreferences,
  ) {
    val imagePath = widgetData.getString("latest_image_path", null)
    val bitmap = imagePath?.let { BitmapFactory.decodeFile(it) }

    appWidgetIds.forEach { widgetId ->
      val views =
          RemoteViews(context.packageName, R.layout.latest_moment_widget).apply {
            setOnClickPendingIntent(
                R.id.widget_root,
                HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java),
            )
            if (bitmap != null) {
              setImageViewBitmap(R.id.widget_image, bitmap)
              setViewVisibility(R.id.widget_image, View.VISIBLE)
              setViewVisibility(R.id.widget_empty_label, View.GONE)
            } else {
              setViewVisibility(R.id.widget_image, View.GONE)
              setViewVisibility(R.id.widget_empty_label, View.VISIBLE)
            }
          }
      appWidgetManager.updateAppWidget(widgetId, views)
    }
  }
}
