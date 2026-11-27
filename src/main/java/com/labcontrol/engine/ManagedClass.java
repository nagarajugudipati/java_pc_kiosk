package com.labcontrol.engine;

import com.fasterxml.jackson.databind.JsonNode;
import com.labcontrol.service.SupabaseService;

import java.io.IOException;
import java.nio.file.Path;
import java.time.Instant;
import java.time.ZoneId;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

public final class ManagedClass implements AutoCloseable {
    // Class policies only affect tested application names in this inventory.
    private static final Set<String> MANAGED = Set.of(
            "notepad.exe", "calc.exe", "calculatorapp.exe", "mspaint.exe",
            "chrome.exe", "msedge.exe", "firefox.exe", "brave.exe", "opera.exe",
            "winword.exe", "excel.exe", "powerpnt.exe", "vlc.exe", "code.exe",
            "teams.exe", "zoom.exe", "discord.exe", "spotify.exe", "blender.exe");

    private record Student(String id, String classCode, String roll, String name) {}
    private record Rules(long version, long deadline, Set<String> blocked, String status) {}

    private final SupabaseService service = SupabaseService.shared();
    private final ScheduledExecutorService heartbeat = scheduler("ClassPolicyHeartbeat");
    private final ScheduledExecutorService monitoring = scheduler("ClassProcessMonitor");
    private final String pc = service.computerName();
    private final String user = ProcessHandle.current().info().user().orElse("");
    private volatile Student student;
    private volatile Rules rules;
    private static final ZoneId REPORT_ZONE = ZoneId.of("Asia/Kolkata");
    private record Focus(Student student, String process, long startedAt, long lastSample) {}
    private Focus focus;
    private BrowserBridge browser;
    private JsonNode websites;
    private long websiteVersion = -1;

    public ManagedClass() {
        String pairing = System.getenv("KIOSK_BROWSER_TOKEN");
        if (pairing != null && pairing.matches("[A-Za-z0-9_-]{32,128}")) {
            try { browser = new BrowserBridge(pairing, this::browserPolicy, this::browserEvent); }
            catch (IOException e) { System.err.println("Could not start the managed browser bridge."); }
        }
        heartbeat.scheduleWithFixedDelay(this::refresh, 0, 10, TimeUnit.SECONDS);
        monitoring.scheduleWithFixedDelay(this::scan, 0, 2, TimeUnit.SECONDS);
    }

    private static ScheduledExecutorService scheduler(String name) {
        return Executors.newSingleThreadScheduledExecutor(task -> {
            Thread thread = new Thread(task, name);
            thread.setDaemon(true);
            return thread;
        });
    }

    public String sessionStatus() {
        if (student == null) return "No active class";
        Rules current = rules;
        if (current == null) return "Joined. Waiting for class policy.";
        if (System.nanoTime() >= current.deadline()) return "Policy expired. Waiting for the kiosk to reconnect.";
        return "Class active. Monitoring and restrictions are running.";
    }

    public void join(String code, String roll, String name) throws IOException, InterruptedException {
        JsonNode joined = service.control("kiosk_join_class", Map.of("p_code", code, "p_roll", roll, "p_name", name));
        if (joined.hasNonNull("error")) throw new IOException(joined.path("error").asText());
        String id = joined.path("student_session").asText();
        String classCode = joined.path("class_code").asText();
        if (id.isBlank() || classCode.isBlank()) throw new IOException("The server did not confirm a class session.");
        synchronized (this) {
            finishFocus(System.currentTimeMillis());
            rules = null;
            websites = null;
            websiteVersion = -1;
            student = new Student(id, classCode, roll, name);
        }
        heartbeat.execute(this::refresh);
    }

    private void refresh() {
        Student current = student;
        if (current == null) return;
        Rules previous = rules;
        try {
            Map<String, Object> parameters = new HashMap<>();
            parameters.put("p_student", current.id());
            parameters.put("p_applied", previous == null ? null : previous.version());
            parameters.put("p_status", previous == null ? "PENDING" : previous.status());
            JsonNode response = service.control("kiosk_heartbeat", parameters);
            synchronized (this) {
                if (student != current) return;
                if (!response.path("active").asBoolean()) {
                    finishFocus(System.currentTimeMillis());
                    student = null;
                    rules = null;
                    websites = null;
                    websiteVersion = -1;
                    System.out.println("Class ended. Class restrictions were removed.");
                    return;
                }
                Set<String> blocked = new HashSet<>();
                String status = "APPLIED";
                if (response.path("blocked").isArray()) {
                    boolean allowlist = response.path("mode").asText().equals("ALLOWLIST");
                    if (allowlist) {
                        blocked.addAll(MANAGED);
                        blocked.remove("code.exe");
                    }
                    for (JsonNode process : response.path("blocked")) {
                        if (!MANAGED.contains(process.asText())) status = "FAILED";
                        else if (allowlist) blocked.remove(process.asText());
                        else if ("code.exe".equals(process.asText())) status = "FAILED";
                        else blocked.add(process.asText());
                    }
                } else if (previous != null) {
                    blocked.addAll(previous.blocked());
                    status = previous.status();
                } else {
                    return;
                }
                long lease = Math.max(0, Math.min(120, response.path("lease_seconds").asLong()));
                rules = new Rules(response.path("version").asLong(), System.nanoTime() + TimeUnit.SECONDS.toNanos(lease),
                        Set.copyOf(blocked), status);
            }
            long version = response.path("version").asLong();
            if (browser != null && version != websiteVersion) {
                JsonNode fetched = service.control("kiosk_device_website_rules", Map.of("p_student", current.id()));
                synchronized (this) {
                    if (student == current && fetched.isArray()) {
                        websites = fetched;
                        websiteVersion = version;
                    }
                }
            }
        } catch (IOException e) {
            System.err.println("Class service temporarily unavailable.");
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private synchronized Map<String, ?> browserPolicy() {
        if (student == null || rules == null || websites == null) return Map.of("leaseMs", 0);
        long lease = TimeUnit.NANOSECONDS.toMillis(rules.deadline() - System.nanoTime());
        if (lease <= 0) return Map.of("leaseMs", 0);
        return Map.of("leaseMs", lease, "session", student.id(), "rules", websites);
    }

    private synchronized void browserEvent(JsonNode event) {
        if (student == null || rules == null || websites == null || System.nanoTime() >= rules.deadline()
                || !student.id().equals(event.path("session").asText())) return;
        String domain = event.path("domain").asText();
        String action = event.path("action").asText();
        if (domain.length() > 240 || !domain.matches("[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+")
                || !(action.equals("OPENED") || action.equals("BLOCKED"))) return;
        Student current = student;
        service.logClassActivity(pc, domain, "web:" + domain, action, current.classCode(), current.roll(), current.id());
        if (action.equals("OPENED")) {
            service.addClassUsage(current.classCode(), domain, "web:" + domain, current.name(), current.roll(), current.id());
        }
    }

    private void scan() {
        Student current = student;
        Rules currentRules = rules;
        if (current == null || currentRules == null || System.nanoTime() >= currentRules.deadline()
                || user.isBlank() || !System.getProperty("os.name").startsWith("Windows")) {
            synchronized (this) { finishFocus(System.currentTimeMillis()); }
            return;
        }
        Set<String> blockedLogged = new HashSet<>();
        try (var processes = ProcessHandle.allProcesses()) {
            processes.forEach(process -> {
                if (student != current || rules != currentRules || System.nanoTime() >= currentRules.deadline()) return;
                String name = managedName(process);
                if (name == null || !currentRules.blocked().contains(name)) return;
                String app = UsageMonitor.getFriendlyAppName(name);
                synchronized (this) {
                    if (student != current || rules != currentRules || System.nanoTime() >= currentRules.deadline()) return;
                    if (currentRules.blocked().contains(name)) {
                        if (process.destroyForcibly()) {
                            if (blockedLogged.add(name)) {
                                service.logClassActivity(pc, app, name, "BLOCKED", current.classCode(), current.roll(), current.id());
                            }
                        } else if (process.isAlive()) {
                            rules = new Rules(currentRules.version(), currentRules.deadline(), currentRules.blocked(), "FAILED");
                        }
                    }
                }
            });
        } catch (RuntimeException e) {
            System.err.println("Unable to inspect managed applications.");
        }
        sampleForeground(current, currentRules);
    }

    private String managedName(ProcessHandle process) {
        var metadata = process.info();
        if (!user.equalsIgnoreCase(metadata.user().orElse("")) || metadata.command().isEmpty()) return null;
        String name = Path.of(metadata.command().orElseThrow()).getFileName().toString().toLowerCase(Locale.ROOT);
        return MANAGED.contains(name) ? name : null;
    }

    private synchronized void sampleForeground(Student current, Rules currentRules) {
        if (student != current || rules != currentRules || System.nanoTime() >= currentRules.deadline()) return;
        long now = System.currentTimeMillis();
        String process = null;
        try {
            process = ProcessHandle.of(WindowsForeground.processId()).map(this::managedName).orElse(null);
            if (process != null && currentRules.blocked().contains(process)) process = null;
        } catch (RuntimeException | LinkageError e) {
            finishFocus(now);
            return;
        }
        if (focus != null && focus.student() == current && focus.process().equals(process)
                && now - focus.lastSample() <= 5000 && now >= focus.lastSample()) {
            focus = new Focus(current, process, focus.startedAt(), now);
            return;
        }
        finishFocus(now);
        if (process != null) {
            focus = new Focus(current, process, now, now);
            service.logClassActivity(pc, UsageMonitor.getFriendlyAppName(process), process, "OPENED",
                    current.classCode(), current.roll(), current.id());
        }
    }

    private void finishFocus(long now) {
        Focus finished = focus;
        focus = null;
        if (finished == null) return;
        long end = Math.min(now, finished.lastSample() + 2000);
        for (long start = finished.startedAt(); start < end;) {
            long midnight = Instant.ofEpochMilli(start).atZone(REPORT_ZONE).toLocalDate().plusDays(1)
                    .atStartOfDay(REPORT_ZONE).toInstant().toEpochMilli();
            long until = Math.min(end, midnight);
            Student current = finished.student();
            service.addClassUsage(current.classCode(), UsageMonitor.getFriendlyAppName(finished.process()),
                    finished.process(), current.name(), current.roll(), current.id(), start, (until - start) / 1000);
            start = until;
        }
    }

    public void leave() {
        Student previous;
        synchronized (this) {
            finishFocus(System.currentTimeMillis());
            previous = student;
            student = null;
            rules = null;
            websites = null;
            websiteVersion = -1;
        }
        if (previous == null) return;
        try {
            service.control("kiosk_leave_class", Map.of("p_student", previous.id()));
        } catch (IOException e) {
            System.err.println("Class was left locally. Server presence will expire.");
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    @Override
    public void close() {
        leave();
        if (browser != null) browser.close();
        heartbeat.shutdownNow();
        monitoring.shutdownNow();
    }
}
