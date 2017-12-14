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

var autoScalingController = function autoScalingController($http) {
    var self = this;
    self.memoryMessage = 'Waiting for user input.';
    self.responseTimeMessage = 'Waiting for user input.';
    self.throughputMessage = 'Waiting for user input.';
    self.syncMessage = 'Waiting for user input.';
    self.memoryValue = 0;
    self.responseTimeValue = 0;
    self.throughputValue = 0;
    self.workers = [];
    self.intervals = {};

    self.displayMemoryValue = function displayMemoryValue(memVal, memUnit) {
        return (memVal/memUnit).toFixed(3);
    };

    self.requestMemory = function requestMemory(memValue) {
        self.memoryMessage = 'Sending request...';
        $http.post('/memory', {"value": memValue}, {timeout: 60000})
        .then(function onSuccess(response) {
                self.memoryMessage = 'Success! Memory value has been adjusted.';
              },
              function onFailure(response) {
                var errStr = 'Failure with error code ' + response.status;
                if (response.data) {
                    errStr += ': ' + response.data;
                }
                self.memoryMessage = errStr;
        });
    };

    self.requestThroughput = function requestThroughput(throughputValue) {
        self.throughputMessage = 'Adjusting throughput...';
        for (var i = 0; i < self.workers.length; i++) {
            worker.postMessage({workerNum: i, interval: self.intervals[i], requests: throughputValue, endpoint: '/requestJSON'});
        }
        self.throughputMessage = 'Throughput adjusted. Notifying server...';
        $http.post('/throughput', {"value": throughputValue}, {timeout: 60000})
        .then(function onSuccess(response) {
            self.throughputMessage = 'Throughput has been adjusted and the server has been notified.';
        },
        function onFailure(response) {
            var errStr = 'Throughput has been adjusted but there was a failure notifying the server. Error code ' + response.status;
            if (response.data) {
                errStr += ': ' + response.data;
            }
            self.throughputMessage = errStr;
        });
    };

    self.checkMessageResponse = function checkMessageResponse(e) {
        if (e.data.type == 'interval') {
            self.intervals[e.data.workerNum] = e.data.interval;
        } else if (e.data.type == 'error') {
            console.log(e.data);
        }
    };

    // We have a pool of 30 web workers.
    for (var i = 0; i < 30; i++) {
        var worker = new Worker('js/throughputGenerator.js');
        worker.onmessage = self.checkMessageResponse;
        self.workers.push(worker);
    }

    self.setResponseDelay = function setResponseDelay(responseTime) {
        self.responseTimeMessage = 'Sending request...';
        $http.post('/responseTime', {"value": responseTime}, {timeout: 60000})
        .then(function onSuccess(response) {
            self.responseTimeMessage = 'Success! Delay has been changed.';
        },
        function onFailure(response) {
            var errStr = 'Failure with error code ' + response.status;
            if (response.data) {
                errStr += ': ' + response.data;
            }
            self.responseTimeMessage = errStr;
        });
    };

    self.syncValues = function syncValues() {
        self.syncMessage = 'Syncing...';
        $http.get('/sync', {timeout: 60000})
        .then(function onSuccess(response) {
            self.memoryValue = response.data.memoryValue;
            self.responseTimeValue = response.data.responseTimeValue;
            self.syncMessage = 'Data values synced.';
        },
        function onFailure(response) {
            var errStr = 'Failure with error code ' + response.status;
            if (response.data) {
                errStr += ': ' + response.data;
            }
            self.syncMessage = errStr;
        });
    };
};
