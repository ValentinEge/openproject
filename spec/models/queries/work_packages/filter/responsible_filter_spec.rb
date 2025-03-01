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
# See COPYRIGHT and LICENSE files for more details.
#++

require 'spec_helper'

describe Queries::WorkPackages::Filter::ResponsibleFilter, type: :model do
  let(:instance) do
    filter = described_class.create!
    filter.values = values
    filter.operator = operator
    filter
  end

  let(:operator) { '=' }
  let(:values) { [] }

  describe 'where filter results' do
    let(:work_package) { FactoryBot.create(:work_package, responsible: responsible) }
    let(:responsible) { FactoryBot.create(:user) }
    let(:group) { FactoryBot.create(:group) }

    subject { WorkPackage.where(instance.where) }

    context 'for the user value' do
      let(:values) { [responsible.id.to_s] }

      it 'returns the work package' do
        is_expected
          .to match_array [work_package]
      end
    end

    context 'for the me value with the user being logged in' do
      let(:values) { ['me'] }

      before do
        allow(User)
          .to receive(:current)
          .and_return(responsible)
      end

      it 'returns the work package' do
        is_expected
          .to match_array [work_package]
      end

      it 'returns the corrected value object' do
        objects = instance.value_objects

        expect(objects.size).to eq(1)
        expect(objects.first.id).to eq 'me'
        expect(objects.first.name).to eq 'me'
      end
    end

    context 'for the me value with another user being logged in' do
      let(:values) { ['me'] }

      before do
        allow(User)
          .to receive(:current)
          .and_return(FactoryBot.create(:user))
      end

      it 'does not return the work package' do
        is_expected
          .to be_empty
      end
    end

    context 'for me and user values' do
      let(:user) { FactoryBot.create :user }
      let(:responsible2) { FactoryBot.create :user }
      let(:values) { [responsible.id, user.id, 'me', responsible2.id] }

      before do
        # Order is important here for ids,
        # otherwise the value_objects will return <user> due to its id
        responsible
        responsible2
        user
        values

        allow(User)
          .to receive(:current)
          .and_return(user)
      end

      it 'returns the mapped value' do
        objects = instance.value_objects

        # The first value is guaranteed to be 'me'.
        # There is no order on the other values.
        expect(objects.map(&:id)[0]).to eql 'me'
        expect(objects.map(&:id)[1..-1]).to match_array [responsible.id, responsible2.id]
      end
    end

    context 'for a group value with the group being assignee' do
      let(:responsible) { group }
      let(:values) { [group.id.to_s] }

      it 'returns the work package' do
        is_expected
          .to match_array [work_package]
      end
    end

    context 'for a group value with a group member being assignee' do
      let(:values) { [group.id.to_s] }
      let(:group) { FactoryBot.create(:group, members: responsible) }

      it 'does not return the work package' do
        is_expected
          .to be_empty
      end
    end

    context 'for a group value with no group member being assignee' do
      let(:values) { [group.id.to_s] }

      it 'does not return the work package' do
        is_expected
          .to be_empty
      end
    end

    context "for a user value with the user's group being assignee" do
      let(:values) { [user.id.to_s] }
      let(:responsible) { group }
      let(:user) { FactoryBot.create(:user) }
      let(:group) { FactoryBot.create(:group, members: user) }

      it 'does not return the work package' do
        is_expected
          .to be_empty
      end
    end

    context "for a user value with the user not being member of the assigned group" do
      let(:values) { [user.id.to_s] }
      let(:responsible) { group }
      let(:user) { FactoryBot.create(:user) }

      it 'does not return the work package' do
        is_expected
          .to be_empty
      end
    end

    context 'for an unmatched value' do
      let(:values) { ['0'] }

      it 'does not return the work package' do
        is_expected
          .to be_empty
      end
    end
  end

  it_behaves_like 'basic query filter' do
    let(:type) { :list_optional }
    let(:class_key) { :responsible_id }

    let(:user_1) { FactoryBot.build_stubbed(:user) }

    let(:principal_loader) do
      loader = double('principal_loader')
      allow(loader)
        .to receive(:principal_values)
        .and_return([])

      loader
    end

    before do
      allow(Queries::WorkPackages::Filter::PrincipalLoader)
        .to receive(:new)
        .with(project)
        .and_return(principal_loader)
    end

    describe '#available?' do
      let(:logged_in) { true }

      before do
        allow(User)
          .to receive_message_chain(:current, :logged?)
          .and_return(logged_in)
      end

      context 'when being logged in' do
        it 'is true if no other user is available' do
          expect(instance).to be_available
        end

        it 'is true if there is another user selectable' do
          allow(principal_loader)
            .to receive(:principal_values)
            .and_return([user_1.name, user_1.id.to_s])

          expect(instance).to be_available
        end
      end

      context 'when not being logged in' do
        let(:logged_in) { false }

        it 'is false if no other user is available' do
          expect(instance).to_not be_available
        end

        it 'is true if there is another user selectable' do
          allow(principal_loader)
            .to receive(:principal_values)
            .and_return([[user_1.name, user_1.id.to_s]])

          expect(instance).to be_available
        end
      end
    end

    describe '#allowed_values' do
      let(:logged_in) { true }
      let(:group) { FactoryBot.build_stubbed(:group) }

      before do
        allow(User)
          .to receive_message_chain(:current, :logged?)
          .and_return(logged_in)

        allow(principal_loader)
          .to receive(:principal_values)
          .and_return([[user_1.name, user_1.id.to_s],
                       [group.name, group.id.to_s]])
      end

      context 'when being logged in' do
        it 'returns the me value, the available users, and groups' do
          expect(instance.allowed_values)
            .to match_array([[I18n.t(:label_me), 'me'],
                             [user_1.name, user_1.id.to_s],
                             [group.name, group.id.to_s]])
        end
      end

      context 'when not being logged in' do
        let(:logged_in) { false }

        it 'returns the available users' do
          expect(instance.allowed_values)
            .to match_array([[user_1.name, user_1.id.to_s],
                             [group.name, group.id.to_s]])
        end
      end
    end

    describe '#ar_object_filter?' do
      it 'is true' do
        expect(instance)
          .to be_ar_object_filter
      end
    end

    describe '#value_objects' do
      let(:user) { FactoryBot.build_stubbed(:user) }
      let(:user2) { FactoryBot.build_stubbed(:user) }

      before do
        allow(Principal)
          .to receive(:where)
          .with(id: [user.id.to_s, user2.id.to_s])
          .and_return([user, user2])

        instance.values = [user.id.to_s, user2.id.to_s]
      end

      it 'returns an array of objects' do
        expect(instance.value_objects)
          .to match_array([user, user2])
      end
    end
  end
end
