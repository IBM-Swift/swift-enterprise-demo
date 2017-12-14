/**
 * Copyright IBM Corporation 2017
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import Kitura
import LoggerAPI
import Foundation
import Configuration
import CloudEnvironment

class StickySession: RouterMiddleware {
    let JSESSIONID: String?
    
    init(configMgr: ConfigurationManager) {
        if configMgr.isLocal == false, let appData = configMgr.getApp() {
            self.JSESSIONID = "\(appData.instanceIndex)"
        } else {
            self.JSESSIONID = nil
        }
    }
    
    func handle(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
        if let sessionCookie = request.cookies["JSESSIONID"], sessionCookie.value != self.JSESSIONID {
            Log.warning("Session ID cookie does not match server instance ID. Session cookie has value \(sessionCookie.value) while server has instance ID \(String(describing: self.JSESSIONID)).")
        }

        defer {
            next()
        }

        guard let sessionID = self.JSESSIONID else {
            return
        }
        
        var properties: [HTTPCookiePropertyKey: Any] = [:]
        properties[HTTPCookiePropertyKey.name] = "JSESSIONID"
        properties[HTTPCookiePropertyKey.value] = sessionID
        properties[HTTPCookiePropertyKey.path] = "/"
        properties[HTTPCookiePropertyKey.originURL] = request.urlURL
        if let stickyCookie = HTTPCookie(properties: properties) {
            response.cookies["JSESSIONID"] = stickyCookie
        } else {
            Log.warning("Could not create session cookie for request to \(request.urlURL.absoluteString)")
        }
    }
}
