import Foundation

enum ProcessClassifier {
    static func classify(name: String, executable: String?, command: String) -> ProcessRuntime {
        let haystack = [name, executable ?? "", command].joined(separator: " ").lowercased()
        let matches: [(ProcessRuntime, [String])] = [
            (.vite, ["vite"]),
            (.next, ["next dev", "next-server"]),
            (.angular, ["ng serve", "angular"]),
            (.springBoot, ["spring-boot", "springframework.boot"]),
            (.gradle, ["gradle", "gradlew"]),
            (.maven, ["mvn", "maven"]),
            (.django, ["manage.py runserver", "django"]),
            (.fastAPI, ["uvicorn", "fastapi"]),
            (.flask, ["flask run", "flask"]),
            (.rails, ["rails server", "puma"]),
            (.postgreSQL, ["postgres", "postmaster"]),
            (.mysql, ["mysqld"]),
            (.redis, ["redis-server"]),
            (.mongoDB, ["mongod"]),
            (.elasticsearch, ["elasticsearch"]),
            (.kubernetes, ["kubectl port-forward"]),
            (.sshTunnel, ["ssh -l", "ssh -r", "ssh -d", "ssh -n"]),
            (.docker, ["docker", "com.docker"]),
            (.node, ["node", "npm", "pnpm", "yarn", "bun"]),
            (.java, ["/java", " java"]),
            (.python, ["python"]),
            (.go, ["go run", "/go/"]),
            (.rust, ["cargo run", "/target/debug/", "/target/release/"]),
            (.php, ["php -s", "php-fpm"])
        ]
        return matches.first(where: { _, needles in needles.contains(where: haystack.contains) })?.0 ?? .unknown
    }
}

enum SystemProcessClassifier {
    private static let protectedNames: Set<String> = [
        "launchd", "kernel_task", "securityd", "trustd", "loginwindow", "opendirectoryd",
        "WindowServer", "coreaudiod", "notifyd", "powerd", "runningboardd", "syspolicyd"
    ]

    static func isSystemProcess(name: String, executable: String?, owner: String, currentDirectory: String?) -> Bool {
        if owner == "root" { return true }
        if protectedNames.contains(name) { return true }
        if let executable, executable.hasPrefix("/System/") || executable.hasPrefix("/usr/sbin/") { return true }
        if let currentDirectory, currentDirectory.hasPrefix("/System/") { return true }
        return false
    }
}

