package com.ghostty.sessionsharing;

import android.os.Bundle;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(WebUpdatePlugin.class);
        super.onCreate(savedInstanceState);
    }
}
