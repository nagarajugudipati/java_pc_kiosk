package com.labcontrol.cli;

import com.labcontrol.engine.ProcessMonitor;
import com.labcontrol.engine.ManagedClass;
import com.labcontrol.engine.UsageMonitor;
import com.labcontrol.model.Policy;
import com.labcontrol.service.PolicyManager;

import java.util.Scanner;

public class CommandLineApp {

    public void start() {

        Scanner sc = new Scanner(System.in);

        System.out.println("Lab Control CLI Started");

        PolicyManager pm = new PolicyManager();
        Policy policy = pm.load();

        ProcessMonitor monitor = new ProcessMonitor();
        UsageMonitor usageMonitor = null;

        try (ManagedClass managed = new ManagedClass()) {
            while (true) {

                System.out.print("> ");
                if (!sc.hasNextLine()) return;
                String input = sc.nextLine();

                String[] parts = input.trim().split(" ");
                String cmd = parts[0];

                switch (cmd) {

                    case "exit":
                        if (usageMonitor != null) {
                            usageMonitor.stop();
                        }
                        return;

                    case "block-app":
                        policy.blockedApps.add(parts[1]);
                        pm.save(policy);
                        System.out.println("Blocked app: " + parts[1]);
                        break;

                    case "block-site":
                        policy.blockedSites.add(parts[1]);
                        pm.save(policy);
                        System.out.println("Blocked site: " + parts[1]);
                        break;

                    case "set-mode":
                        policy.mode = parts[1];
                        pm.save(policy);
                        System.out.println("Mode set: " + parts[1]);
                        break;

                    case "status":
                        System.out.println("Mode: " + policy.mode);
                        System.out.println("Blocked Apps: " + policy.blockedApps);
                        System.out.println("Blocked Sites: " + policy.blockedSites);
                        break;

                    case "start":
                        monitor.start(policy);
                        System.out.println("Monitoring started...");
                        break;

                    case "usage-start":
                        String[] session = input.trim().split("\\s+", 3);
                        if (session.length == 2) {
                            System.out.println("Usage: usage-start <class_code> <student_name>");
                            break;
                        }
                        if (usageMonitor == null) {
                            usageMonitor = new UsageMonitor();
                        }
                        if (session.length == 3 && session[2].startsWith("--student-id ")) {
                            String[] identity = session[2].split("\\s+", 3);
                            if (identity.length != 3) {
                                System.out.println("Usage: usage-start <class_code> --student-id <id> <student_name>");
                                break;
                            }
                            usageMonitor.start(session[1], identity[2], identity[1]);
                        } else if (session.length == 3) {
                            usageMonitor.start(session[1], session[2]);
                        } else {
                            usageMonitor.start("576107", "Unknown");
                        }
                        break;

                    case "usage-stop":
                        if (usageMonitor != null) {
                            usageMonitor.stop();
                        }
                        break;

                    case "join-class":
                        String[] join = input.trim().split("\\s+", 4);
                        if (join.length != 4) {
                            System.out.println("Usage: join-class <code> <roll_number> <student_name>");
                            break;
                        }
                        try {
                            managed.join(join[1], join[2], join[3]);
                            System.out.println("Class joined. Application monitoring starts after the policy is received.");
                        } catch (java.io.IOException e) {
                            System.err.println(e.getMessage());
                        } catch (InterruptedException e) {
                            Thread.currentThread().interrupt();
                            return;
                        }
                        break;

                    case "leave-class":
                        managed.leave();
                        break;

                    default:
                        System.out.println("Unknown command");
                }
            }
        }
    }
}
