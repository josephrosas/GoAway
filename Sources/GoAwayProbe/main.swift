import Foundation
import GoAwayCore

// Started by GoAway while it shows the permission screen. A Full Disk Access
// grant only reaches processes launched after it, so this fresh process can see
// a grant the running app cannot. Exit 0 means granted.
switch FullDiskAccess.status() {
case .granted: exit(0)
case .denied: exit(1)
case .unknown: exit(2)
}
