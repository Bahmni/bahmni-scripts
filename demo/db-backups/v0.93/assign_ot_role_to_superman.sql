INSERT INTO user_role(user_id, role) values((select user_id from users where username='superman'), 'OT: FullAccess');

INSERT INTO location (name, description, retired, uuid, date_created, creator) VALUES ('OT', 'Operation Theater', FALSE, uuid(), NOW(), 1);

SELECT location_tag_id INTO @location_tag_id FROM location_tag WHERE name = "Operation Theater" and description = "Operation Theater";

SELECT location_id INTO @location_id FROM location WHERE location.name="OT" and description = "Operation Theater";

INSERT INTO location_tag_map(location_id, location_tag_id) VALUES(@location_id, @location_tag_id);