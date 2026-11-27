package com.labcontrol.engine;

import com.labcontrol.model.Policy;
import com.labcontrol.service.SupabaseService;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;

public class ProcessMonitor {

    private final SupabaseService supabaseService;
    private final String pcName;
    private final AtomicBoolean started = new AtomicBoolean();

    public ProcessMonitor() {
        this(SupabaseService.shared().computerName(), SupabaseService.shared());
    }

    public ProcessMonitor(String pcName, SupabaseService supabaseService) {
        this.pcName = pcName;
        this.supabaseService = supabaseService;
    }

    public void start(Policy policy) {
        if (!started.compareAndSet(false, true)) {
            return;
        }

        new Thread(() -> {

            Set<String> previousProcesses = new HashSet<>();
            boolean isBaselineEstablished = false;

            while (true) {
                try {
                    Set<String> currentProcesses = new HashSet<>();
                    Process process = Runtime.getRuntime().exec("tasklist");

                    try (BufferedReader reader = new BufferedReader(
                            new InputStreamReader(process.getInputStream())
                    )) {
                        String line;
                        while ((line = reader.readLine()) != null) {
                            String lowerLine = line.toLowerCase();
                            if (!lowerLine.contains(".exe")) continue;
                            String processName = line.split("\\s+")[0].toLowerCase();
                            currentProcesses.add(processName);
                        }
                    }

                    if (!isBaselineEstablished) {
                        previousProcesses.addAll(currentProcesses);
                        isBaselineEstablished = true;
                    } else {
                        for (String processName : currentProcesses) {
                            if (UsageMonitor.isIgnoredProcess(processName)) {
                                continue;
                            }
                            if (!previousProcesses.contains(processName)) {
                                String appName = UsageMonitor.getFriendlyAppName(processName);
                                boolean isBlocked = policy.blockedApps.stream()
                                        .anyMatch(app -> processName.contains(app.toLowerCase()) || app.toLowerCase().contains(processName.replace(".exe", "")));

                                if (isBlocked) {
                                    System.out.println("[BLOCKED] " + appName + " (" + processName + ") on " + pcName);
                                    supabaseService.logActivity(pcName, appName, processName, "BLOCKED");
                                    Runtime.getRuntime().exec("taskkill /F /IM " + processName);
                                } else {
                                    System.out.println("[OPENED] " + appName + " (" + processName + ") on " + pcName);
                                    supabaseService.logActivity(pcName, appName, processName, "OPENED");
                                }
                            } else {
                                boolean isBlocked = policy.blockedApps.stream()
                                        .anyMatch(app -> processName.contains(app.toLowerCase()) || app.toLowerCase().contains(processName.replace(".exe", "")));
                                if (isBlocked) {
                                    Runtime.getRuntime().exec("taskkill /F /IM " + processName);
                                }
                            }
                        }
                        previousProcesses = currentProcesses;
                    }

                    Thread.sleep(2000);

                } catch (Exception e) {
                    System.err.println("Error in ProcessMonitor loop: " + e.getMessage());
                }
            }

        }, "ProcessMonitorThread").start();
    }
}
