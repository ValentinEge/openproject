#-- copyright
# OpenProject is an open source project management software.
# Copyright (C) 2012-2021 the OpenProject GmbH
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See docs/COPYRIGHT.rdoc for more details.
#++

module OpenProject::Backlogs
  module Patches
    module UserPreferences
      module SchemaPatch
        def self.included(base)
          class << base
            prepend(ClassMethods)
          end
        end

        module ClassMethods
          def schema
            ret = super

            properties = ret.dig('definitions', 'UserPreferences', 'properties')

            properties['backlogs_task_color'] = {
              'type' => 'string'
            }

            properties['backlogs_versions_default_fold_state'] = {
              'type' => 'string',
              "enum" => %w[open closed]
            }

            ret
          end
        end
      end
    end
  end
end
