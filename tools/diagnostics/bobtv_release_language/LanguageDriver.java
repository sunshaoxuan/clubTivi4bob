package com.briconbric.bobtv.qai18n;

import android.app.Activity;
import android.app.Instrumentation;
import android.app.UiAutomation;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.MotionEvent;
import android.view.InputDevice;
import android.view.accessibility.AccessibilityNodeInfo;
import java.util.ArrayList;
import java.util.List;

public final class LanguageDriver extends Instrumentation {
    private Bundle arguments;
    @Override public void onCreate(Bundle args) {
        super.onCreate(args);
        arguments = args;
        start();
    }
    @Override public void onStart() {
        Bundle result = new Bundle();
        try {
            UiAutomation ui = getUiAutomation();
            String[] operations = arguments.getString("steps", "").split("\\|");
            for (String operation : operations) {
                String label = operation.substring(1);
                long deadline = SystemClock.uptimeMillis() + 65000;
                Rect target = null;
                List<String> labels = new ArrayList<>();
                do {
                    labels.clear();
                    target = find(ui.getRootInActiveWindow(), label, labels);
                    if (target != null) break;
                    SystemClock.sleep(280);
                } while (SystemClock.uptimeMillis() < deadline);
                if (target == null) throw new AssertionError("Missing " + label + " in " + labels);
                if (operation.startsWith("+")) {
                    long when = SystemClock.uptimeMillis();
                    MotionEvent down = MotionEvent.obtain(when, when, MotionEvent.ACTION_DOWN, target.centerX(), target.centerY(), 0);
                    down.setSource(InputDevice.SOURCE_TOUCHSCREEN);
                    ui.injectInputEvent(down, true);
                    MotionEvent up = MotionEvent.obtain(when, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, target.centerX(), target.centerY(), 0);
                    up.setSource(InputDevice.SOURCE_TOUCHSCREEN);
                    ui.injectInputEvent(up, true);
                    down.recycle();
                    up.recycle();
                    SystemClock.sleep(450);
                }
            }
            result.putString("matched", String.join("|", operations));
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            result.putString("driverError", error.toString());
            finish(Activity.RESULT_CANCELED, result);
        }
    }
    private static Rect find(AccessibilityNodeInfo node, String text, List<String> labels) {
        if (node == null) return null;
        CharSequence[] values = {node.getText(), node.getContentDescription(), node.getTooltipText()};
        for (CharSequence value : values) {
            if (value == null) continue;
            labels.add(value.toString());
            for (String line : value.toString().split("\\n")) {
                if (text.equals(line.trim()) && node.isVisibleToUser()) {
                    Rect rect = new Rect();
                    node.getBoundsInScreen(rect);
                    if (!rect.isEmpty()) return rect;
                }
            }
        }
        for (int i = 0; i < node.getChildCount(); i++) {
            Rect rect = find(node.getChild(i), text, labels);
            if (rect != null) return rect;
        }
        return null;
    }
}
