##
# Copyright IBM Corporation 2017
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
##

set -e

if [[ $TRAVIS_BRANCH = "master" ]]; then
    echo "Building with 'production' credentials..."
    ./Package-Builder/build-package.sh -projectDir $TRAVIS_BUILD_DIR -credentialsDir $TRAVIS_BUILD_DIR/Testing-Credentials/swift-enterprise-demo/production
else
    echo "Building with 'development' credentials..."
    ./Package-Builder/build-package.sh -projectDir $TRAVIS_BUILD_DIR -credentialsDir $TRAVIS_BUILD_DIR/Testing-Credentials/swift-enterprise-demo/development
fi
