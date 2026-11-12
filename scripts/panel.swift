// Opens a Şerit panel from the command line: swift scripts/panel.swift volume|brightness|more|close
import Foundation
DistributedNotificationCenter.default().postNotificationName(Notification.Name("local.serit.panel"), object: CommandLine.arguments.dropFirst().first ?? "close", userInfo: nil, deliverImmediately: true)
