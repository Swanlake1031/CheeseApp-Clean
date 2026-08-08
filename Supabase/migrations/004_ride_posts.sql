-- ============================================
-- 004_ride_posts.sql
-- 拼车模块数据库表
-- 
-- 📖 这是什么？
-- 这个文件创建拼车相关的数据库表
-- 用于发布和查找拼车信息
-- 
-- 📝 使用场景：
-- - 开车的同学发布顺风车，找人分摊油费
-- - 没车的同学找顺风车
-- - 去机场、购物、活动等场景
-- ============================================


-- ============================================
-- 拼车详情表 (ride_posts)
-- ============================================

CREATE TABLE ride_posts (
  -- 主键，关联到 posts 表
  id UUID PRIMARY KEY REFERENCES posts(id) ON DELETE CASCADE,
  
  -- ============================================
  -- 地点信息
  -- ============================================
  
  -- departure_location 出发地点
  departure_location TEXT NOT NULL,
  
  -- departure_lat/lng 出发地坐标（用于地图显示和距离计算）
  departure_lat NUMERIC(10,8),
  departure_lng NUMERIC(11,8),
  
  -- destination_location 目的地
  destination_location TEXT NOT NULL,
  
  -- destination_lat/lng 目的地坐标
  destination_lat NUMERIC(10,8),
  destination_lng NUMERIC(11,8),
  
  -- ============================================
  -- 时间信息
  -- ============================================
  
  -- departure_time 出发时间
  -- TIMESTAMPTZ 带时区的时间戳，可以准确处理不同时区
  departure_time TIMESTAMPTZ NOT NULL,
  
  -- is_flexible 时间是否灵活
  -- TRUE 表示出发时间可以商量
  is_flexible BOOLEAN DEFAULT FALSE,
  
  -- ============================================
  -- 角色和座位
  -- ============================================
  
  -- role 发布者的角色
  -- driver: 我是司机，找乘客
  -- passenger: 我是乘客，找司机/拼车伙伴
  role TEXT NOT NULL CHECK (role IN ('driver', 'passenger')),
  
  -- total_seats 提供的座位数（司机填写）
  -- 例如：车有4个座，自己坐1个，提供3个
  total_seats INTEGER CHECK (total_seats >= 0),
  
  -- available_seats 剩余座位数
  -- 有人加入后会减少
  available_seats INTEGER CHECK (available_seats >= 0),
  
  -- ============================================
  -- 价格信息
  -- ============================================
  
  -- price_per_seat 每个座位的价格
  -- NULL 表示免费或待商议
  price_per_seat NUMERIC(10,2) CHECK (price_per_seat >= 0),
  
  -- is_free 是否免费
  is_free BOOLEAN DEFAULT FALSE,
  
  -- ============================================
  -- 联系方式
  -- ============================================
  
  -- contact_method 首选联系方式
  -- app: 通过 App 聊天
  -- wechat: 微信
  -- phone: 电话
  -- text: 短信
  contact_method TEXT DEFAULT 'app' CHECK (contact_method IN ('app', 'wechat', 'phone', 'text')),
  
  -- contact_info 联系方式详情
  -- 例如：微信号、电话号码
  contact_info TEXT,
  
  -- ============================================
  -- 额外信息
  -- ============================================
  
  -- has_luggage_space 是否有行李空间
  has_luggage_space BOOLEAN DEFAULT TRUE,
  
  -- pets_allowed 是否允许带宠物
  pets_allowed BOOLEAN DEFAULT FALSE,
  
  -- smoking_allowed 是否允许吸烟
  smoking_allowed BOOLEAN DEFAULT FALSE,
  
  -- notes 备注
  -- 例如：车型、要求、注意事项等
  notes TEXT
);


-- ============================================
-- 创建索引
-- ============================================

-- 出发时间索引（用于查找即将出发的行程）
-- 按时间升序，方便查找最近的行程
CREATE INDEX ride_posts_departure_time_idx ON ride_posts (departure_time ASC);

-- 角色索引（用于筛选司机或乘客）
CREATE INDEX ride_posts_role_idx ON ride_posts (role);

-- 地点全文搜索索引
-- 合并出发地和目的地进行搜索
CREATE INDEX ride_posts_location_idx ON ride_posts 
  USING GIN (to_tsvector('english', departure_location || ' ' || destination_location));

-- 有空位的行程索引
CREATE INDEX ride_posts_available_idx ON ride_posts (available_seats) 
  WHERE available_seats > 0;


-- ============================================
-- 创建拼车帖子的便捷函数
-- ============================================

CREATE OR REPLACE FUNCTION create_ride_post(
  p_user_id UUID,
  p_title TEXT,
  p_description TEXT,
  p_departure_location TEXT,
  p_destination_location TEXT,
  p_departure_time TIMESTAMPTZ,
  p_role TEXT,
  p_total_seats INTEGER DEFAULT NULL,
  p_price_per_seat NUMERIC DEFAULT NULL,
  p_is_free BOOLEAN DEFAULT FALSE,
  p_is_flexible BOOLEAN DEFAULT FALSE,
  p_contact_method TEXT DEFAULT 'app',
  p_is_anonymous BOOLEAN DEFAULT FALSE
)
RETURNS UUID AS $$
DECLARE
  v_post_id UUID;
BEGIN
  -- 创建基础帖子
  INSERT INTO posts (user_id, type, title, description, is_anonymous)
  VALUES (p_user_id, 'ride', p_title, p_description, p_is_anonymous)
  RETURNING id INTO v_post_id;
  
  -- 创建拼车详情
  INSERT INTO ride_posts (
    id, departure_location, destination_location, departure_time,
    role, total_seats, available_seats, price_per_seat,
    is_free, is_flexible, contact_method
  )
  VALUES (
    v_post_id, p_departure_location, p_destination_location, p_departure_time,
    p_role, p_total_seats, p_total_seats,  -- available_seats 初始等于 total_seats
    p_price_per_seat, p_is_free, p_is_flexible, p_contact_method
  );
  
  RETURN v_post_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;


-- ============================================
-- 创建拼车帖子视图
-- ============================================

CREATE OR REPLACE VIEW ride_posts_view AS
SELECT 
  r.*,
  p.user_id,
  p.title,
  p.description,
  p.status,
  p.is_anonymous,
  p.view_count,
  p.created_at,
  p.updated_at,
  pr.full_name AS user_name,
  pr.avatar_url AS user_avatar,
  pr.university AS user_university,
  pr.verified AS user_verified,
  -- 计算是否已满员
  CASE 
    WHEN r.role = 'driver' AND r.available_seats <= 0 THEN TRUE
    ELSE FALSE
  END AS is_full,
  -- 计算是否已过期（出发时间已过）
  CASE 
    WHEN r.departure_time < NOW() THEN TRUE
    ELSE FALSE
  END AS is_expired
FROM ride_posts r
JOIN posts p ON r.id = p.id
JOIN profiles pr ON p.user_id = pr.id
WHERE p.status = 'active'
  -- 只显示未过期的行程（出发时间在1小时后之前的都显示）
  AND r.departure_time > (NOW() - INTERVAL '1 hour');


-- ============================================
-- 拼车参与者表
-- ============================================
-- 
-- 🎯 这个表的作用：
-- 记录谁加入了哪个拼车
-- 类似于订单表

CREATE TABLE ride_participants (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- 拼车帖子
  ride_id UUID REFERENCES ride_posts(id) ON DELETE CASCADE NOT NULL,
  
  -- 参与者
  user_id UUID REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  
  -- 预定的座位数
  seats_booked INTEGER NOT NULL DEFAULT 1 CHECK (seats_booked > 0),
  
  -- 状态
  -- pending: 待确认
  -- confirmed: 已确认
  -- cancelled: 已取消
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'cancelled')),
  
  -- 留言
  message TEXT,
  
  -- 创建时间
  created_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- 每个用户对同一个拼车只能有一条记录
  UNIQUE(ride_id, user_id)
);


-- ============================================
-- 减少可用座位的触发器
-- ============================================
-- 
-- 🎯 当参与者状态变为 confirmed 时
-- 自动减少可用座位数

CREATE OR REPLACE FUNCTION update_available_seats()
RETURNS TRIGGER AS $$
BEGIN
  -- 如果新状态是 confirmed
  IF NEW.status = 'confirmed' AND (OLD.status IS NULL OR OLD.status != 'confirmed') THEN
    UPDATE ride_posts 
    SET available_seats = available_seats - NEW.seats_booked
    WHERE id = NEW.ride_id;
  -- 如果从 confirmed 变成其他状态（取消）
  ELSIF OLD.status = 'confirmed' AND NEW.status != 'confirmed' THEN
    UPDATE ride_posts 
    SET available_seats = available_seats + OLD.seats_booked
    WHERE id = NEW.ride_id;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER ride_participants_seats_trigger
  AFTER INSERT OR UPDATE ON ride_participants
  FOR EACH ROW
  EXECUTE FUNCTION update_available_seats();


-- ============================================
-- 🎉 完成！
-- ============================================
