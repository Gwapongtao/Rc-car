package com.example.flutter_application_1_voice_command

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    private lateinit var connectivity: ConnectivityManager

    private val wifiCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                connectivity.bindProcessToNetwork(network)
            }
        }

        override fun onLost(network: Network) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                connectivity.bindProcessToNetwork(null)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        connectivity.requestNetwork(request, wifiCallback)
    }

    override fun onDestroy() {
        connectivity.unregisterNetworkCallback(wifiCallback)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            connectivity.bindProcessToNetwork(null)
        }
        super.onDestroy()
    }
}